defmodule Loom.Agent.Backend.KiroTest do
  @moduledoc """
  The ACP adapter against shapes captured from `kiro-cli acp` 3.2.0 (v3
  engine), trimmed to the fields the adapter reads. `port` is an atom, so
  writes are swallowed and decoding stays a pure function.
  """
  use ExUnit.Case, async: true

  alias Loom.Agent.Backend
  alias Loom.Agent.Backend.Kiro

  @sid "sess_a371345f-c781-45f8-9d5e-8c6b3cc54e63"

  defp ready(overrides \\ %{}) do
    {:ok, handle} = Kiro.resume("a_test", %{kiro_session_id: @sid})

    handle
    |> Map.merge(%{
      port: :fake_port,
      phase: :ready,
      prompt_id: 7,
      announced?: true,
      requests: %{7 => :prompt}
    })
    |> Map.merge(overrides)
  end

  defp feed(handle, messages) do
    chunk = Enum.map_join(List.wrap(messages), "", &(Jason.encode!(&1) <> "\n"))
    {:ok, handle, out} = Kiro.decode(handle, {:fake_port, {:data, chunk}})
    {handle, out}
  end

  defp events(out), do: for({:event, kind, payload} <- out, do: {kind, payload})

  defp update(update, sid \\ @sid) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => sid, "update" => update}
    }
  end

  defp message_chunk(text, replay \\ "r1-say"),
    do:
      update(%{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text},
        "_meta" => %{"kiro" => %{"replayId" => replay}}
      })

  defp thought_chunk(text, replay \\ "r0-say"),
    do:
      update(%{
        "sessionUpdate" => "agent_thought_chunk",
        "content" => %{"type" => "text", "text" => text},
        "_meta" => %{"kiro" => %{"replayId" => replay}}
      })

  defp info(kiro),
    do: update(%{"sessionUpdate" => "session_info_update", "_meta" => %{"kiro" => kiro}})

  defp reply(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  describe "kind" do
    test "is parsed, labelled and resolved like the others" do
      assert Backend.parse("kiro") == {:ok, :kiro}
      assert Backend.parse(:kiro) == {:ok, :kiro}
      assert Backend.label(:kiro) == "Kiro"
      assert Backend.impl(:kiro) == Kiro
    end
  end

  describe "handshake" do
    defp booting(session_id) do
      {:ok, handle} = Kiro.resume("a_test", %{kiro_session_id: session_id, instructions: "LOOM"})

      Map.merge(handle, %{
        port: :fake_port,
        phase: :initializing,
        next_id: 2,
        requests: %{1 => :initialize},
        pending: {:prompt, "hello"}
      })
    end

    test "a new conversation is opened, then the waiting prompt goes out" do
      {handle, []} = feed(booting(nil), reply(1, %{"protocolVersion" => 1}))
      assert handle.phase == :opening
      assert handle.requests == %{2 => :new}

      {handle, out} = feed(handle, reply(2, %{"sessionId" => "sess_new"}))
      assert [{:status, %{status: :running, backend_ref: "sess_new"}}] = events(out)
      assert handle.phase == :ready
      assert handle.prompt_id == 3
      assert handle.pending == nil
      assert Kiro.persist(handle) == %{kiro_session_id: "sess_new", kiro_cwd: handle.cwd}
    end

    test "a recorded conversation is loaded, and its replay is not news" do
      {handle, []} = feed(booting(@sid), reply(1, %{}))
      assert handle.requests == %{2 => :load}

      # session/load replays history as ordinary updates before it replies.
      {handle, []} = feed(handle, [message_chunk("old answer"), thought_chunk("old thought")])
      assert handle.block == nil

      {handle, out} =
        feed(
          handle,
          reply(2, %{"modes" => %{}, "_meta" => %{"contextUsage" => %{"usagePercentage" => 4.0}}})
        )

      assert [{:status, %{status: :running}}] = events(out)
      assert handle.prompt_id == 3
      assert handle.context_tokens == 40_000
    end

    test "a conversation that cannot be loaded is opened afresh" do
      {handle, []} = feed(booting(@sid), reply(1, %{}))

      {handle, []} =
        feed(handle, %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "error" => %{"code" => -32002, "message" => "session not found"}
        })

      assert handle.session_id == nil
      assert handle.requests == %{3 => :new}
      assert handle.pending == {:prompt, "hello"}
    end

    test "a load reply with no modes is not a session, so one is opened" do
      {handle, []} = feed(booting(@sid), reply(1, %{}))
      {handle, []} = feed(handle, reply(2, %{"_meta" => %{}}))
      assert handle.session_id == nil
      assert handle.requests == %{3 => :new}
    end

    test "new and load approve everything and carry Loom's instructions as steering" do
      handle = booting(nil)

      for params <- [Kiro.session_params(handle, nil), Kiro.session_params(handle, @sid)] do
        kiro = params["_meta"]["kiro"]
        assert kiro["policyPreset"] == ["allow-all"]

        assert [%{"name" => "loom", "inclusion" => "always", "content" => "LOOM"}] =
                 kiro["steering"]
      end

      assert Kiro.session_params(handle, @sid)["_meta"]["kiro"]["noReplay"] == true
      refute Map.has_key?(Kiro.session_params(handle, nil)["_meta"]["kiro"], "noReplay")
    end

    test "with no instructions there is no steering" do
      {:ok, handle} = Kiro.resume("a_test", %{})
      refute Map.has_key?(Kiro.session_params(handle, nil)["_meta"]["kiro"], "steering")
    end

    test "the configured model and effort are set once the session is open" do
      settings = %{model: "claude-opus-5.5", effort: "high", args: [], env: %{}}
      {handle, []} = feed(%{booting(nil) | settings: settings}, reply(1, %{}))
      {handle, _out} = feed(handle, reply(2, %{"sessionId" => "sess_new"}))

      tags = handle.requests |> Map.values() |> Enum.sort()
      assert tags == Enum.sort([:set_model, :set_effort, :prompt])
    end

    test "with nothing configured no option is set" do
      {handle, []} = feed(booting(nil), reply(1, %{}))
      {handle, _out} = feed(handle, reply(2, %{"sessionId" => "sess_new"}))
      assert Map.values(handle.requests) == [:prompt]
    end

    test "a refused option is only logged" do
      handle = ready(%{requests: %{7 => :prompt, 8 => :set_model}})

      assert {_, []} =
               feed(handle, %{
                 "jsonrpc" => "2.0",
                 "id" => 8,
                 "error" => %{"code" => -32602, "message" => "Invalid value"}
               })
    end

    test "a message typed while booting goes out with the prompt" do
      assert {:ok, %{pending: {:prompt, "hello\n\nand this"}}} =
               Kiro.steer(booting(nil), "and this")
    end

    test "an interrupt while booting means the prompt never goes out" do
      {:ok, handle} = Kiro.interrupt(booting(nil))
      {handle, []} = feed(handle, reply(1, %{}))
      {handle, out} = feed(handle, reply(2, %{"sessionId" => "sess_new"}))
      assert out == []
      assert handle.prompt_id == nil
    end
  end

  describe "streaming" do
    test "message chunks are one block, closed by a tool call" do
      {handle, out} = feed(ready(), [message_chunk("Hel"), message_chunk("lo")])

      assert [
               {:delta, %{type: :block_start, block_type: :text, block_id: id}},
               {:delta, %{type: :text, chunk: "Hel", block_id: id}},
               {:delta, %{type: :text, chunk: "lo", block_id: id}}
             ] = out

      {_handle, out} =
        feed(
          handle,
          update(%{
            "sessionUpdate" => "tool_call",
            "toolCallId" => "run_command_toolu_1",
            "title" => "List first three entries in /tmp",
            "kind" => "execute",
            "status" => "pending",
            "rawInput" => %{"command" => "ls /tmp | head -3", "__tool_use_purpose" => "x"}
          })
        )

      assert [
               {:delta, %{type: :block_end, block_id: ^id}},
               {:event, :assistant_text, %{block_id: ^id, text: "Hello"}},
               {:delta, %{type: :tool_use_start, name: "shell", block_id: "run_command_toolu_1"}},
               {:event, :tool_use,
                %{
                  id: "run_command_toolu_1",
                  name: "shell",
                  input: %{
                    "command" => "ls /tmp | head -3",
                    "description" => "List first three entries in /tmp"
                  }
                }}
             ] = out
    end

    test "thinking and text are separate blocks" do
      {handle, out} = feed(ready(), [thought_chunk("hmm"), message_chunk("Answer")])
      assert [{:thinking, %{text: "hmm", block_id: thinking}}] = events(out)

      {_handle, out} = feed(handle, reply(7, %{"stopReason" => "end_turn"}))
      assert [{:assistant_text, %{text: "Answer", block_id: text}}, {:turn_done, _}] = events(out)
      refute thinking == text
    end

    test "a new replayId starts a new block" do
      {handle, out} =
        feed(ready(), [message_chunk("one", "a-say"), message_chunk("two", "b-say")])

      assert [{:assistant_text, %{text: "one"}}] = events(out)
      {_handle, out} = feed(handle, reply(7, %{"stopReason" => "end_turn"}))
      assert [{:assistant_text, %{text: "two"}}, {:turn_done, _}] = events(out)
    end

    test "a finished tool reports its output" do
      handle = ready(%{tools: %{"t1" => "shell"}})

      {_handle, out} =
        feed(
          handle,
          update(%{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "t1",
            "status" => "completed",
            "rawOutput" => %{"output" => "a\n", "exitCode" => 0},
            "content" => [
              %{"type" => "content", "content" => %{"type" => "text", "text" => "Output:\na\n"}}
            ]
          })
        )

      assert [{:tool_result, %{id: "t1", name: "shell", status: :ok, output: "Output:\na\n"}}] =
               events(out)
    end

    test "a failed tool is an error, and v2's streamed output is a delta" do
      handle = ready(%{tools: %{"t1" => "shell"}})

      {_handle, out} =
        feed(
          handle,
          update(%{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "t1",
            "content" => [
              %{"type" => "content", "content" => %{"type" => "text", "text" => "hi\n"}}
            ]
          })
        )

      assert [{:delta, %{type: :tool_output, block_id: "t1", chunk: "hi\n"}}] = out

      {_handle, out} =
        feed(
          handle,
          update(%{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => "t1",
            "status" => "failed"
          })
        )

      assert [{:tool_result, %{status: :error}}] = events(out)
    end

    test "replayed and sub-agent frames are not this conversation's" do
      replayed =
        message_chunk("old") |> put_in(["params", "update", "_meta", "kiro", "replay"], true)

      sub =
        message_chunk("sub")
        |> put_in(["params", "update", "_meta", "kiro", "agentSubtaskId"], "st1")

      assert {%{block: nil}, []} = feed(ready(), [replayed, sub])
    end

    test "updates for another session are not ours" do
      assert {_, []} =
               feed(ready(), message_chunk("x") |> put_in(["params", "sessionId"], "other"))
    end

    test "other ports' messages are ignored" do
      assert Kiro.decode(ready(), {:other_port, {:data, "{}\n"}}) == :ignore
    end
  end

  describe "running" do
    test "a warm process's turn is announced by the engine's first word" do
      # A live port, so run_turn/2 writes to it instead of spawning kiro-cli.
      port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["30"]])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      {:ok, handle} = Kiro.run_turn(ready(%{port: port, prompt_id: nil}), "again")
      refute handle.announced?
      handle = %{handle | port: :fake_port}

      {handle, out} = feed(handle, message_chunk("hi"))
      assert [{:status, %{status: :running, backend_ref: @sid}}] = events(out)

      {_handle, out} = feed(handle, message_chunk(" there"))
      assert events(out) == []
    end

    test "a turn the engine said nothing during is still announced before it ends" do
      {_handle, out} = feed(ready(%{announced?: false}), reply(7, %{"success" => true}))
      assert [{:status, %{status: :running}}, {:turn_done, _}] = events(out)
    end
  end

  describe "turn end" do
    test "the prompt's reply ends the turn, with the context" do
      handle = ready()
      {handle, []} = feed(handle, info(context_info(4.0)))
      {handle, _} = feed(handle, message_chunk("done"))
      {handle, out} = feed(handle, reply(7, %{"stopReason" => "end_turn"}))

      assert [
               {:assistant_text, %{text: "done"}},
               {:turn_done,
                %{stop_reason: "end_turn", context_tokens: 40_000, context_window: 1_000_000}}
             ] = events(out)

      assert handle.prompt_id == nil
    end

    test "an error reply fails the turn with its message" do
      {_handle, out} =
        feed(ready(), %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "error" => %{"code" => -32603, "message" => "Internal error", "data" => "throttled"}
        })

      assert [{:turn_failed, %{reason: "Internal error: throttled"}}] = events(out)
    end

    test "the reply to an interrupt we asked for is silent" do
      {:ok, handle} = Kiro.interrupt(ready())
      assert handle.interrupted?
      {handle, out} = feed(handle, reply(7, %{"stopReason" => "cancelled"}))
      assert events(out) == []
      refute handle.interrupted?
    end

    test "the reply to an older prompt is not this turn's end" do
      {handle, out} =
        feed(
          ready(%{requests: %{7 => :prompt, 5 => :prompt}}),
          reply(5, %{"stopReason" => "cancelled"})
        )

      assert out == []
      assert handle.prompt_id == 7
    end

    test "the real window comes with turn_completion" do
      {handle, []} =
        feed(
          ready(),
          info(%{
            "kind" => "turn_completion",
            "contextBreakdown" => %{
              "window" => %{"sizeTokens" => 200_000, "usagePercentage" => 10}
            }
          })
        )

      assert {handle.context_tokens, handle.context_window} == {20_000, 200_000}
    end

    test "an error's type is kept in the reason" do
      {_handle, out} =
        feed(ready(), %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "error" => %{
            "code" => -32000,
            "message" => "The usage limit has been reached.",
            "data" => %{"errorType" => "MonthlyLimitError"}
          }
        })

      assert [{:turn_failed, %{reason: "The usage limit has been reached. (MonthlyLimitError)"}}] =
               events(out)
    end

    test "a failed summarisation fails the turn if the engine goes quiet" do
      failed =
        info(%{
          "kind" => "summarization_failed",
          "summarization" => %{
            "status" => "failed",
            "error" => %{"reason" => "context window overflowed"}
          }
        })

      {handle, []} = feed(ready(), failed)
      assert handle.compaction_error == "context window overflowed"

      {:ok, handle, out} = Kiro.decode(handle, {:kiro_timer, :fake_port, :compaction, 7})

      assert [
               {:turn_failed,
                %{reason: "kiro could not compact the conversation: context window overflowed"}}
             ] =
               events(out)

      assert handle.prompt_id == nil
      # The late reply, if it ever comes, is not a second ending.
      assert {_, []} = feed(handle, reply(7, %{"stopReason" => "end_turn"}))
    end

    test "a timer for a prompt that already ended does nothing" do
      handle = ready(%{prompt_id: 9})
      assert {:ok, ^handle, []} = Kiro.decode(handle, {:kiro_timer, :fake_port, :compaction, 7})
    end

    test "a cancel the engine never answers kills the process" do
      {:ok, handle} = Kiro.interrupt(ready())
      {:ok, handle, out} = Kiro.decode(handle, {:kiro_timer, :fake_port, :cancel, 7})
      assert out == []
      assert {handle.port, handle.phase, handle.prompt_id} == {nil, nil, nil}
      refute handle.interrupted?
    end

    test "a compaction is reported, and its reply ends the turn" do
      {handle, out} =
        feed(
          ready(),
          info(%{
            "kind" => "summarization_completed",
            "summarization" => %{"status" => "success"}
          })
        )

      assert [{:compacted, %{}}] = events(out)
      {_handle, out} = feed(handle, reply(7, %{"success" => true}))
      assert [{:turn_done, _}] = events(out)
    end
  end

  describe "engine requests" do
    test "a question for the user is answered, not left hanging" do
      question = %{
        "jsonrpc" => "2.0",
        "id" => 40,
        "method" => "_kiro/userInput",
        "params" => %{"sessionId" => @sid, "question" => "Which file?"}
      }

      assert {_, []} = feed(ready(), question)
    end
  end

  describe "steering" do
    test "joins the running turn" do
      {:ok, handle} = Kiro.steer(ready(), "also this")
      assert [{"loom-steer-" <> _ = id, "also this"}] = handle.steers
      assert handle.requests[handle.next_id - 1] == {:steer, id}
    end

    test "is refused with no turn to join, so the session queues it" do
      assert {:error, _} = Kiro.steer(ready(%{prompt_id: nil}), "late")
    end

    test "an injected steer is done with, under the name Kiro gave it" do
      {:ok, handle} = Kiro.steer(ready(), "also this")
      [{ours, _}] = handle.steers
      request = handle.next_id - 1

      {handle, []} =
        feed(handle, reply(request, %{"queued" => true, "messageId" => "steer-" <> ours}))

      {handle, []} =
        feed(handle, info(%{"kind" => "steering_injected", "messageId" => "steer-" <> ours}))

      assert handle.steers == []
      {_handle, out} = feed(handle, reply(7, %{"stopReason" => "end_turn"}))
      assert [{:turn_done, _}] = events(out)
    end

    test "one the turn ended without becomes the next prompt" do
      {:ok, handle} = Kiro.steer(ready(), "also this")
      {handle, out} = feed(handle, reply(7, %{"stopReason" => "end_turn"}))
      assert events(out) == []
      assert handle.steers == []
      assert is_integer(handle.prompt_id) and handle.prompt_id != 7
    end
  end

  describe "context" do
    test "the window is inferred from the breakdown and snapped" do
      {handle, []} = feed(ready(), info(context_info(1.1)))
      assert handle.context_window == 1_000_000
      assert handle.context_tokens == 11_000
    end

    test "without a breakdown the last window is kept" do
      {handle, []} =
        feed(
          ready(%{context_window: 200_000}),
          info(%{"kind" => "context_usage", "usagePercentage" => 50})
        )

      assert {handle.context_tokens, handle.context_window} == {100_000, 200_000}
    end
  end

  describe "process exit" do
    test "mid-turn it fails the turn" do
      {handle, _out} = feed(ready(), message_chunk("partial"))
      {:ok, handle, out} = Kiro.decode(handle, {:fake_port, {:exit_status, 1}})

      assert [{:assistant_text, %{text: "partial"}}, {:turn_failed, %{reason: reason}}] =
               events(out)

      assert reason =~ "status 1"
      assert handle.port == nil
    end

    test "between turns it is only logged" do
      {:ok, handle, out} = Kiro.decode(ready(%{prompt_id: nil}), {:fake_port, {:exit_status, 0}})
      assert out == []
      assert handle.phase == nil
    end

    test "one we killed is swallowed" do
      port = Port.open({:spawn, "true"}, [:exit_status])
      assert {:ok, _, []} = Kiro.decode(ready(), {port, {:exit_status, 137}})
    end
  end

  describe "resume" do
    test "a session that never ran has nothing to load and will open one" do
      assert {:ok, %{session_id: nil}} = Kiro.resume("a_test", %{})
    end

    test "string keys in the header are accepted" do
      assert {:ok, %{session_id: @sid, cwd: "/srv"}} =
               Kiro.resume("a_test", %{"kiro_session_id" => @sid, "kiro_cwd" => "/srv"})
    end
  end

  defp context_info(pct) do
    %{
      "kind" => "context_usage",
      "usagePercentage" => pct,
      "breakdown" => %{
        "tools" => %{"tokens" => 5669, "percent" => 0.6},
        "yourPrompts" => %{"tokens" => 0, "percent" => 3.5}
      }
    }
  end
end
