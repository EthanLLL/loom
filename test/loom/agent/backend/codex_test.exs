defmodule Loom.Agent.Backend.CodexTest do
  @moduledoc """
  The Codex translation layer against real `codex app-server` notifications.

  Shapes are taken from notifications captured off the running server and from
  the protocol schema it generates itself (`codex app-server
  generate-json-schema`), so a protocol change shows up here rather than as
  silently missing events in the UI.
  """
  use ExUnit.Case, async: true

  alias Loom.Agent.Backend.Codex

  @thread "01a1384e-61df-7ae1-b26c-063c421c7d40"
  @turn "01a1384e-6b9d-7ad1-bb36-db5c7b771f26"

  defp handle(overrides \\ %{}) do
    Map.merge(
      %{
        thread_id: @thread,
        turn_id: @turn,
        aborted?: false,
        stale?: false,
        tools: %{},
        usage: nil,
        context_tokens: 0,
        context_window: nil
      },
      overrides
    )
  end

  defp feed(handle, method, params) do
    {:ok, handle, out} =
      Codex.decode(handle, {:codex, @thread, %{"method" => method, "params" => params}})

    {handle, out}
  end

  defp events(out), do: for({:event, kind, payload} <- out, do: {kind, payload})
  defp deltas(out), do: for({:delta, delta} <- out, do: delta)

  describe "routing" do
    test "a notification for another thread is not ours" do
      # One session must never consume another's output — they share one
      # app-server, so this is the only thing keeping them apart.
      message = %{"method" => "turn/started", "params" => %{}}
      assert Codex.decode(handle(), {:codex, "some-other-thread", message}) == :ignore
    end

    test "a deliberate restart only marks the thread for reattaching" do
      # Sent by `Server.reload/0`, which restarts only with no turn running:
      # unlike `:codex_down`, there is no failed turn to report.
      assert {:ok, handle, []} = Codex.decode(handle(), {:codex_reloaded, @thread})
      assert handle.stale?
      assert Codex.decode(handle(), {:codex_reloaded, "some-other-thread"}) == :ignore
    end

    test "unrelated process messages fall through" do
      assert Codex.decode(handle(), :timeout) == :ignore
      assert Codex.decode(handle(), {:port, {:data, "x"}}) == :ignore
    end
  end

  describe "turn lifecycle" do
    test "turn/started records the turn id, which interrupting needs" do
      {handle, out} =
        feed(handle(%{turn_id: nil}), "turn/started", %{
          "threadId" => @thread,
          "turn" => %{"id" => @turn, "status" => "inProgress"}
        })

      assert handle.turn_id == @turn
      assert [{:status, %{status: :running, backend_ref: @turn}}] = events(out)
    end

    test "context comes from `last`, not the turn's running `total`" do
      # Verbatim from a four-step shell task: the conversation stayed ~15.5K
      # while `total` climbed to 77K, because each tool call re-reads the cached
      # prefix. Reporting `total` as context would show five times the truth.
      usages = [
        %{"last" => %{"inputTokens" => 15_154}, "total" => %{"totalTokens" => 15_216}},
        %{"last" => %{"inputTokens" => 15_351}, "total" => %{"totalTokens" => 45_909}},
        %{
          "last" => %{"inputTokens" => 15_522},
          "total" => %{"totalTokens" => 76_954},
          "modelContextWindow" => 258_400
        }
      ]

      handle =
        Enum.reduce(usages, handle(), fn usage, acc ->
          {acc, _} =
            feed(acc, "thread/tokenUsage/updated", %{
              "threadId" => @thread,
              "tokenUsage" => usage
            })

          acc
        end)

      {handle, out} =
        feed(handle, "turn/completed", %{
          "threadId" => @thread,
          "turn" => %{"id" => @turn, "status" => "completed"}
        })

      assert [{:turn_done, %{context_tokens: 15_522, context_window: 258_400}}] = events(out)
      # Cleared, so a later interrupt cannot address a turn that is over.
      assert handle.turn_id == nil
    end

    test "an interrupted turn produces no event — the session owns that" do
      # Measured: turn/interrupt yields turn/completed with status "interrupted".
      # Reporting it here as well would double-report the abort.
      {handle, out} =
        feed(handle(%{aborted?: true}), "turn/completed", %{
          "threadId" => @thread,
          "turn" => %{"id" => @turn, "status" => "interrupted"}
        })

      assert out == []
      assert handle.turn_id == nil
      refute handle.aborted?
    end

    test "a failed turn carries its reason" do
      {_handle, out} =
        feed(handle(), "turn/completed", %{
          "threadId" => @thread,
          "turn" => %{"id" => @turn, "status" => "failed", "error" => %{"message" => "no quota"}}
        })

      assert [{:turn_failed, %{reason: "no quota"}}] = events(out)
    end

    # Captured on 0.162.1 against a provider answering every request with 503,
    # `stream_max_retries = 2`, trimmed.
    @retrying %{
      "error" => %{
        "message" => "Reconnecting... 1/2",
        "codexErrorInfo" => %{"responseStreamDisconnected" => %{"httpStatusCode" => 503}},
        "additionalDetails" => "unexpected status 503 Service Unavailable"
      },
      "willRetry" => true,
      "threadId" => @thread,
      "turnId" => @turn
    }

    test "an error Codex will retry is a retry, not the end of the turn" do
      {_handle, out} = feed(handle(), "error", @retrying)

      assert [{:api_retry, %{attempt: 1, max_retries: 2, status: 503}}] = events(out)
    end

    test "the last error is left to `turn/completed`, so the turn fails once" do
      {_handle, out} =
        feed(handle(), "error", %{
          @retrying
          | "error" => %{"message" => "unexpected status 503", "codexErrorInfo" => %{}},
            "willRetry" => false
        })

      assert out == []
    end

    test "an error outside a turn is still reported" do
      {_handle, out} = feed(handle(), "error", %{"error" => %{"message" => "stream closed"}})
      assert [{:turn_failed, %{reason: "stream closed"}}] = events(out)
    end

    test "compaction is reported, not implemented" do
      # Captured from `thread/compact/start` on 0.162.1: the work is an item on
      # an ordinary turn, and `thread/compacted` is no longer sent.
      item = %{"type" => "contextCompaction", "id" => "01a13f17-7eb7-7c82-ae85-6175cb5d1ba2"}

      {_handle, started} =
        feed(handle(), "item/started", %{"threadId" => @thread, "item" => item})

      assert started == []

      {_handle, out} = feed(handle(), "item/completed", %{"threadId" => @thread, "item" => item})
      assert [{:compacted, %{}}] = events(out)
    end

    test "the all-zero usage a compaction reports does not zero the context" do
      # Measured right after a compaction: `last` has every input field at 0.
      # That is "no API call", not an empty conversation.
      {handle, _} =
        feed(handle(%{context_tokens: 11_304}), "thread/tokenUsage/updated", %{
          "threadId" => @thread,
          "tokenUsage" => %{
            "last" => %{"inputTokens" => 0, "totalTokens" => 7158, "outputTokens" => 0},
            "modelContextWindow" => 258_400
          }
        })

      assert handle.context_tokens == 11_304
    end

    test "/compact cannot join a running turn, so it waits in the queue" do
      # Steered in, the model would read it as text. Refusing is what makes the
      # session queue it and run it as its own turn once this one ends.
      assert {:error, _} = Codex.steer(handle(), "/compact")
      assert {:error, _} = Codex.steer(handle(), "  /compact\n")
    end
  end

  describe "assistant messages" do
    test "the item id is the block id, with no turn qualifier needed" do
      # Codex names every item and repeats the name on each delta, so unlike
      # Claude Code's per-response SSE index there is nothing to disambiguate.
      item = %{"type" => "agentMessage", "id" => "msg_abc", "text" => ""}

      {handle, started} = feed(handle(), "item/started", %{"item" => item})

      {handle, d1} =
        feed(handle, "item/agentMessage/delta", %{"itemId" => "msg_abc", "delta" => "Sev"})

      {handle, d2} =
        feed(handle, "item/agentMessage/delta", %{"itemId" => "msg_abc", "delta" => "en"})

      {_handle, done} =
        feed(handle, "item/completed", %{"item" => %{item | "text" => "Seven"}})

      assert [%{block_id: "msg_abc", type: :block_start, block_type: :text}] = deltas(started)
      assert [%{block_id: "msg_abc", type: :text, chunk: "Sev"}] = deltas(d1)
      assert [%{block_id: "msg_abc", type: :text, chunk: "en"}] = deltas(d2)
      assert [%{block_id: "msg_abc", type: :block_end}] = deltas(done)
      assert [{:assistant_text, %{block_id: "msg_abc", text: "Seven"}}] = events(done)
    end

    test "a user message is not echoed back into the transcript" do
      # We already recorded it when the user submitted it.
      {_handle, out} =
        feed(handle(), "item/started", %{
          "item" => %{
            "type" => "userMessage",
            "id" => "u1",
            "content" => [%{"type" => "text", "text" => "hi"}]
          }
        })

      assert out == []
    end
  end

  describe "reasoning" do
    test "streams as thinking and is recorded from whichever field holds it" do
      item = %{"type" => "reasoning", "id" => "rs_1", "summary" => [], "content" => []}
      {handle, _} = feed(handle(), "item/started", %{"item" => item})

      {handle, out} =
        feed(handle, "item/reasoning/summaryTextDelta", %{"itemId" => "rs_1", "delta" => "weigh"})

      assert [%{block_id: "rs_1", type: :thinking, chunk: "weigh"}] = deltas(out)

      # summary and content hold blocks whose shape varies by model, so both are
      # harvested rather than one being assumed.
      {_handle, out} =
        feed(handle, "item/completed", %{
          "item" => %{item | "summary" => [%{"text" => "weighed options"}]}
        })

      assert [{:thinking, %{text: "weighed options"}}] = events(out)
    end

    test "textDelta is treated the same as summaryTextDelta" do
      {_handle, out} =
        feed(handle(), "item/reasoning/textDelta", %{"itemId" => "rs_2", "delta" => "x"})

      assert [%{type: :thinking, chunk: "x"}] = deltas(out)
    end
  end

  describe "tool items" do
    test "a shell command becomes a tool_use and then a tool_result" do
      started = %{
        "type" => "commandExecution",
        "id" => "cmd_1",
        "command" => "ls -la",
        "cwd" => "/tmp",
        "status" => "inProgress"
      }

      {handle, out} = feed(handle(), "item/started", %{"item" => started})

      assert [%{type: :tool_use_start, name: "shell", id: "cmd_1"}] = deltas(out)

      assert [{:tool_use, %{id: "cmd_1", name: "shell", input: input}}] = events(out)
      assert input == %{"command" => "ls -la", "cwd" => "/tmp"}

      {_handle, out} =
        feed(handle, "item/completed", %{
          "item" =>
            Map.merge(started, %{
              "status" => "completed",
              "exitCode" => 0,
              "aggregatedOutput" => "total 0\n"
            })
        })

      assert [{:tool_result, %{id: "cmd_1", name: "shell", status: :ok, output: "total 0\n"}}] =
               events(out)
    end

    test "a non-zero exit is an error even when the status says completed" do
      # The status field describes the call, not the command. A failing build
      # reported as a success is the kind of thing that makes a transcript lie.
      {_handle, out} =
        feed(handle(), "item/completed", %{
          "item" => %{
            "type" => "commandExecution",
            "id" => "cmd_2",
            "status" => "completed",
            "exitCode" => 1,
            "aggregatedOutput" => "boom"
          }
        })

      assert [{:tool_result, %{status: :error, output: "boom"}}] = events(out)
    end

    test "an mcp call is labelled with the tool it called" do
      started = %{
        "type" => "mcpToolCall",
        "id" => "mcp_1",
        "server" => "gateway",
        "tool" => "WebSearch",
        "arguments" => %{"query" => "elixir"}
      }

      {handle, out} = feed(handle(), "item/started", %{"item" => started})
      assert [{:tool_use, %{name: "WebSearch", input: %{"query" => "elixir"}}}] = events(out)

      {_handle, out} =
        feed(handle, "item/completed", %{
          "item" => Map.put(started, "result", %{"content" => [%{"text" => "found it"}]})
        })

      assert [{:tool_result, %{name: "WebSearch", status: :ok, output: "found it"}}] = events(out)
    end

    test "an mcp error is reported as a failure" do
      {_handle, out} =
        feed(handle(), "item/completed", %{
          "item" => %{
            "type" => "mcpToolCall",
            "id" => "mcp_2",
            "tool" => "WebSearch",
            "error" => %{"message" => "gateway 403"}
          }
        })

      assert [{:tool_result, %{status: :error, output: "gateway 403"}}] = events(out)
    end

    test "a patch and a web search both map onto the same card" do
      {_h, patch} =
        feed(handle(), "item/started", %{
          "item" => %{
            "type" => "fileChange",
            "id" => "fc_1",
            "changes" => [%{"path" => "/tmp/a.ex"}]
          }
        })

      assert [{:tool_use, %{name: "apply_patch"}}] = events(patch)

      {_h, search} =
        feed(handle(), "item/started", %{
          "item" => %{"type" => "webSearch", "id" => "ws_1", "query" => "otp 28"}
        })

      assert [{:tool_use, %{name: "web_search", input: %{"query" => "otp 28"}}}] = events(search)
    end

    test "a tool_result keeps the name recorded when the call started" do
      {handle, _} =
        feed(handle(), "item/started", %{
          "item" => %{"type" => "mcpToolCall", "id" => "mcp_3", "tool" => "Weather"}
        })

      assert handle.tools == %{"mcp_3" => "Weather"}
    end

    test "command output streams under the tool card's block id" do
      # Without this a ten-minute build looks hung. The block_id matches the
      # tool_use, so a client appends into the card it already rendered.
      {_handle, out} =
        feed(handle(), "item/commandExecution/outputDelta", %{
          "itemId" => "cmd_1",
          "delta" => "compiling...\n"
        })

      assert [%{block_id: "cmd_1", type: :tool_output, chunk: "compiling...\n"}] = deltas(out)
    end

    test "every flavour of output delta streams the same way" do
      for method <- [
            "item/commandExecution/outputDelta",
            "item/fileChange/outputDelta",
            "process/outputDelta",
            "command/exec/outputDelta"
          ] do
        {_handle, out} = feed(handle(), method, %{"itemId" => "x", "delta" => "tick"})
        assert [%{type: :tool_output, chunk: "tick"}] = deltas(out), "#{method} did not stream"
      end
    end

    test "structured progress with no text field is serialised, not dropped" do
      # The point of streaming is to prove something is happening. A shape we
      # have not special-cased is still evidence of that.
      {_handle, out} =
        feed(handle(), "item/mcpToolCall/progress", %{
          "itemId" => "mcp_1",
          "threadId" => @thread,
          "progress" => %{"done" => 3, "total" => 10}
        })

      assert [%{block_id: "mcp_1", type: :tool_output, chunk: chunk}] = deltas(out)
      assert chunk =~ "done"
      refute chunk =~ @thread
    end
  end

  describe "the app-server dying" do
    test "a restart fails the turn and marks the thread for reattachment" do
      # Without this the session waits forever for a turn nobody is running.
      assert {:ok, handle, out} = Codex.decode(handle(), {:codex_down, @thread})

      assert [{:event, :turn_failed, %{reason: reason}}] = out
      assert reason =~ "restarted"
      assert handle.turn_id == nil
      # The next turn has to resume first: the new app-server has never heard of
      # this thread.
      assert handle.stale?
    end

    test "a death notice for another thread is not ours" do
      assert Codex.decode(handle(), {:codex_down, "another-thread"}) == :ignore
    end
  end

  describe "noise" do
    test "notifications with no place in this UI are dropped, not guessed at" do
      for method <- [
            "thread/status/changed",
            "thread/queue/changed",
            "mcpServer/startupStatus/updated",
            "turn/plan/updated",
            "account/rateLimits/updated",
            "remoteControl/status/changed"
          ] do
        {_handle, out} = feed(handle(), method, %{"threadId" => @thread})
        assert out == [], "#{method} should produce nothing"
      end
    end
  end

  describe "resume" do
    test "refuses to invent a thread id" do
      assert {:error, reason} = Codex.resume("a_1", %{})
      assert reason =~ "codex_thread_id"
    end

    test "a header with string keys is not mistaken for an unbound session" do
      # See the matching Claude Code test: lazy module loading means the header
      # can come back with string keys, and reading only the atom form looks
      # exactly like "never bound to a backend".
      assert {:error, reason} = Codex.resume("a_1", %{"codex_thread_id" => @thread})
      # It got far enough to try the server, which is not running under test.
      refute reason =~ "codex_thread_id"
    end
  end
end
