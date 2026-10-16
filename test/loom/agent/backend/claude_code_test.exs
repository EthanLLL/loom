defmodule Loom.Agent.Backend.ClaudeCodeTest do
  @moduledoc """
  The translation layer against real recorded `claude -p --output-format
  stream-json` output, plus the two things that have actually gone wrong in
  practice: a JSON line split across port reads, and a process tree that
  survives being killed.

  Fixtures are verbatim lines captured from the CLI (Claude Code 2.1.296), not
  invented shapes — the whole value of this adapter is that it matches what the
  binary really emits.
  """
  use ExUnit.Case, async: true

  alias Loom.Agent.Backend.ClaudeCode

  @session_id "f9c5596e-333d-4e1f-b434-aa044ae76532"

  # A handle in the state it would be in mid-turn. `port` is matched
  # structurally, not with is_port/1, so an atom stands in for a real one and
  # the whole decode path stays a pure function.
  defp handle(overrides \\ %{}) do
    base = %{
      session_id: @session_id,
      cwd: "/tmp",
      first_turn?: false,
      port: :fake_port,
      os_pid: nil,
      message_id: "msg_one",
      pending_blocks: [],
      buffer: "",
      tools: %{},
      interrupted?: false,
      next_control_id: 1,
      context_tokens: 0,
      context_window: nil
    }

    Map.merge(base, overrides)
  end

  defp feed(handle, lines) when is_list(lines) do
    feed(handle, Enum.map_join(lines, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp feed(handle, chunk) when is_binary(chunk) do
    {:ok, handle, out} = ClaudeCode.decode(handle, {:fake_port, {:data, chunk}})
    {handle, out}
  end

  defp events(out), do: for({:event, kind, payload} <- out, do: {kind, payload})

  defp ids(items) do
    Enum.flat_map(items, fn
      %{block_id: id} -> [id]
      {_kind, %{block_id: id}} -> [id]
      _ -> []
    end)
  end

  defp deltas(out), do: for({:delta, delta} <- out, do: delta)

  describe "init" do
    test "reports the session id the CLI actually chose" do
      # We mint the uuid, but taking it from init means a CLI that reassigns
      # one cannot silently orphan the conversation.
      {handle, out} =
        feed(handle(%{session_id: "stale"}), [
          %{
            "type" => "system",
            "subtype" => "init",
            "session_id" => @session_id,
            "cwd" => "/private/tmp",
            "tools" => ["Bash", "Edit", "Read"]
          }
        ])

      assert handle.session_id == @session_id
      assert [{:status, %{status: :running, backend_ref: @session_id}}] = events(out)
    end
  end

  describe "streaming text" do
    test "SSE events become deltas and the assistant message becomes the event" do
      {_handle, out} =
        feed(handle(), [
          # Carries the id every later block_id is qualified by.
          %{
            "type" => "stream_event",
            "event" => %{"type" => "message_start", "message" => %{"id" => "msg_one"}}
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "text", "text" => ""}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "O"}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "K"}
            }
          },
          %{"type" => "stream_event", "event" => %{"type" => "content_block_stop", "index" => 0}},
          %{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => "OK"}]}
          }
        ])

      assert [
               %{block_id: "msg_one.0", type: :block_start, block_type: :text},
               %{block_id: "msg_one.0", type: :text, chunk: "O"},
               %{block_id: "msg_one.0", type: :text, chunk: "K"},
               %{block_id: "msg_one.0", type: :block_end}
             ] = deltas(out)

      # The authoritative event carries the same block_id, so a client replaces
      # the placeholder it built from deltas rather than appending a duplicate.
      assert [{:assistant_text, %{block_id: "msg_one.0", text: "OK"}}] = events(out)
    end

    test "an unknown block type stays a string rather than minting an atom" do
      type = "brand_new_block_#{System.unique_integer([:positive])}"

      {_handle, out} =
        feed(handle(), [
          %{
            "type" => "stream_event",
            "event" => %{"type" => "message_start", "message" => %{"id" => "msg_new"}}
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => type}
            }
          }
        ])

      assert [%{type: :block_start, block_type: ^type}] = deltas(out)
      assert_raise ArgumentError, fn -> String.to_existing_atom(type) end
    end

    test "block ids are qualified by the API call, not the turn" do
      # One agentic turn makes an API call per tool round and the SSE `index`
      # restarts at 0 in each. Qualifying by the turn made call 2's first block
      # collide with call 1's, so the second answer streamed into the first
      # one's placeholder — the doubled text seen mid-turn.
      call = fn id, text ->
        [
          %{
            "type" => "stream_event",
            "event" => %{"type" => "message_start", "message" => %{"id" => id, "usage" => %{}}}
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "text"}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => text}
            }
          },
          %{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => text}]}
          }
        ]
      end

      {handle, first} = feed(handle(%{message_id: nil}), call.("msg_aaa", "first"))
      {_handle, second} = feed(handle, call.("msg_bbb", "second"))

      assert Enum.all?((deltas(first) ++ events(first)) |> ids(), &(&1 == "msg_aaa.0"))
      assert Enum.all?((deltas(second) ++ events(second)) |> ids(), &(&1 == "msg_bbb.0"))
    end

    test "thinking is streamed and recorded separately from text" do
      {_handle, out} =
        feed(handle(), [
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "thinking_delta", "thinking" => "hmm"}
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "thinking", "thinking" => "hmm", "signature" => "sig"}]
            }
          }
        ])

      assert [%{type: :thinking, chunk: "hmm"}] = deltas(out)
      assert [{:thinking, %{text: "hmm"}}] = events(out)
    end

    test "partial json deltas are dropped rather than forwarded" do
      # Half a JSON argument list is useless to a client and the authoritative
      # version arrives in the `assistant` message anyway.
      {_handle, out} =
        feed(handle(), [
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 1,
              "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"pa)}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "signature_delta", "signature" => "abc"}
            }
          }
        ])

      assert out == []
    end
  end

  describe "tools" do
    test "a tool call streams a start delta and records id, name and input" do
      {handle, out} =
        feed(handle(), [
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "Bash"}
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_1",
                  "name" => "Bash",
                  "input" => %{"command" => "ls"}
                }
              ]
            }
          }
        ])

      assert [%{type: :tool_use_start, name: "Bash", id: "toolu_1", block_id: "msg_one.0"}] =
               deltas(out)

      assert [{:tool_use, %{id: "toolu_1", name: "Bash", input: %{"command" => "ls"}}}] =
               events(out)

      assert handle.tools == %{"toolu_1" => "Bash"}
    end

    test "a tool result is labelled with the tool that produced it" do
      # The result only carries an id, so the name has to come from state the
      # adapter kept — otherwise every tool card in the UI reads "tool".
      {handle, _} =
        feed(handle(), [
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "tool_use", "id" => "toolu_1", "name" => "Read"}]
            }
          }
        ])

      {_handle, out} =
        feed(handle, [
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "toolu_1",
                  "content" => [%{"type" => "text", "text" => "file contents"}]
                }
              ]
            }
          }
        ])

      assert [
               {:tool_result,
                %{id: "toolu_1", name: "Read", status: :ok, output: "file contents"}}
             ] =
               events(out)
    end

    test "is_error becomes an error status" do
      {_handle, out} =
        feed(handle(), [
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "toolu_9",
                  "is_error" => true,
                  "content" => "boom"
                }
              ]
            }
          }
        ])

      assert [{:tool_result, %{status: :error, output: "boom"}}] = events(out)
    end

    test "a permission denial under automode is surfaced, not swallowed" do
      # Unreachable with bypassPermissions. If it ever fires the model is being
      # silently crippled, so it must reach the transcript.
      {_handle, out} =
        feed(handle(), [
          %{
            "type" => "system",
            "subtype" => "permission_denied",
            "tool_name" => "Write",
            "tool_use_id" => "toolu_2",
            "message" => "Claude requested permissions to write to /tmp/x"
          }
        ])

      assert [{:tool_result, %{status: :error, name: "Write", output: output}}] = events(out)
      assert output =~ "permissions"
    end
  end

  describe "compaction" do
    test "a compact_boundary is reported, and its size becomes the context" do
      # Verbatim shape from a manual `/compact`. The turn that follows is an
      # empty `result/success` with no API call, so without this the UI shows
      # nothing and the old size until the next turn.
      {handle, out} =
        feed(handle(%{context_tokens: 15_723}), [
          %{
            "type" => "system",
            "subtype" => "compact_boundary",
            "session_id" => @session_id,
            "compact_metadata" => %{
              "trigger" => "manual",
              "pre_tokens" => 15_723,
              "post_tokens" => 1257,
              "cumulative_dropped_tokens" => 14_466,
              "duration_ms" => 5263
            }
          },
          %{"type" => "result", "subtype" => "success", "result" => "", "usage" => %{}}
        ])

      assert [
               {:compacted, %{trigger: "manual", pre_tokens: 15_723, post_tokens: 1257}},
               {:turn_done, %{context_tokens: 1257}}
             ] = events(out)

      assert handle.context_tokens == 1257
    end
  end

  describe "turn completion" do
    test "the process is kept, so the next turn starts warm" do
      # Measured: turn 2 on the same process reaches `init` in 0.02 s against
      # 4.65 s cold. Reaping here would make every turn pay the cold start.
      {handle, _} =
        feed(handle(), [%{"type" => "result", "subtype" => "success", "usage" => %{}}])

      assert handle.port == :fake_port
    end

    test "the result of an interrupt we asked for is not reported as a failure" do
      # Claude Code reports a graceful interrupt as `error_during_execution`
      # with `terminal_reason: "aborted_streaming"`. It is not an error, and the
      # session emits its own abort event — reporting it here too would show the
      # user a failure they caused on purpose.
      {_handle, out} =
        feed(handle(%{interrupted?: true}), [
          %{
            "type" => "result",
            "subtype" => "error_during_execution",
            "terminal_reason" => "aborted_streaming",
            "usage" => %{}
          }
        ])

      assert out == []
    end

    test "the flag is cleared, so the next turn reports normally" do
      {handle, _} =
        feed(handle(%{interrupted?: true}), [
          %{"type" => "result", "subtype" => "error_during_execution", "usage" => %{}}
        ])

      refute handle.interrupted?

      {_handle, out} =
        feed(handle, [
          %{"type" => "result", "subtype" => "error_during_execution", "usage" => %{}}
        ])

      assert [{:turn_failed, _}] = events(out)
    end

    @result %{
      "type" => "result",
      "subtype" => "success",
      "stop_reason" => "end_turn",
      "usage" => %{
        "input_tokens" => 2,
        "cache_creation_input_tokens" => 20_906,
        "cache_read_input_tokens" => 10_112,
        "output_tokens" => 4
      }
    }

    test "context comes from the last API call, not the turn's total" do
      # Verbatim from a four-step shell task. `result` sums every call, because
      # each tool call re-reads the cached prefix — reporting that as context
      # told the user 157K when the conversation was 32K.
      calls = [
        %{
          "input_tokens" => 2,
          "cache_read_input_tokens" => 10_112,
          "cache_creation_input_tokens" => 20_958
        },
        %{
          "input_tokens" => 2,
          "cache_read_input_tokens" => 31_070,
          "cache_creation_input_tokens" => 141
        },
        %{
          "input_tokens" => 2,
          "cache_read_input_tokens" => 31_711,
          "cache_creation_input_tokens" => 141
        }
      ]

      lines =
        Enum.map(calls, fn usage ->
          %{
            "type" => "stream_event",
            "event" => %{"type" => "message_start", "message" => %{"usage" => usage}}
          }
        end) ++
          [
            %{
              "type" => "result",
              "subtype" => "success",
              "usage" => %{
                "input_tokens" => 10,
                "cache_read_input_tokens" => 135_674,
                "cache_creation_input_tokens" => 21_740
              },
              "modelUsage" => %{"claude-opus-5[1m]" => %{"contextWindow" => 1_000_000}}
            }
          ]

      {_handle, out} = feed(handle(), lines)

      assert [{:turn_done, payload}] = events(out)
      assert payload.context_tokens == 2 + 31_711 + 141
      refute payload.context_tokens == 10 + 135_674 + 21_740
      assert payload.context_window == 1_000_000
    end

    test "success reports the stop reason and keeps the process warm" do
      {handle, out} = feed(handle(), [@result])

      assert [{:turn_done, payload}] = events(out)
      assert payload.stop_reason == "end_turn"
      # Cost is deliberately not reported: Codex has no USD figure at all, and a
      # number that exists on one backend and not the other is worse than none.
      refute Map.has_key?(payload, :cost_usd)
      assert handle.port == :fake_port
    end

    test "a non-success result is a failure, with its terminal reason" do
      {_handle, out} =
        feed(handle(), [
          %{
            "type" => "result",
            "subtype" => "error_during_execution",
            "terminal_reason" => "aborted_streaming",
            "usage" => %{}
          }
        ])

      assert [{:turn_failed, %{reason: "error_during_execution"}}] = events(out)
    end
  end

  describe "process exit" do
    test "a reaped process confirming it died is swallowed, not logged" do
      # Erlang delivers the exit status even after `Port.close/1`, and release
      # or teardown kills with SIGKILL — so `exit_status 137` for a port we
      # already let go is entirely expected and must not be logged as a
      # surprise on every release.
      port = Port.open({:spawn, "cat"}, [:binary])
      assert {:ok, _handle, []} = ClaudeCode.decode(handle(), {port, {:exit_status, 137}})
      Port.close(port)
    end

    test "exiting with no result at all is reported" do
      # Otherwise the session sits in :running forever with nothing to explain
      # it — the failure mode that makes a background agent look hung.
      assert {:ok, _handle, out} = ClaudeCode.decode(handle(), {:fake_port, {:exit_status, 1}})
      assert [{:event, :turn_failed, %{reason: reason}}] = out
      assert reason =~ "status 1"
    end

    test "messages from another port are not ours" do
      # One session must not consume another's output, and the session's own
      # unrelated messages have to fall through.
      assert ClaudeCode.decode(handle(), {:other_port, {:data, "{}\n"}}) == :ignore
      assert ClaudeCode.decode(handle(), :timeout) == :ignore
    end
  end

  describe "line framing" do
    test "a json object split across reads is reassembled" do
      # Port reads are arbitrary byte chunks. Parsing per-read would drop every
      # large tool result, which is where the long lines are.
      line =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "hello"}]}
        })

      {at, rest} = String.split_at(line <> "\n", 30)

      {handle, out} = feed(handle(), at)
      assert out == []
      assert handle.buffer != ""

      {handle, out} = feed(handle, rest)
      assert [{:assistant_text, %{text: "hello"}}] = events(out)
      assert handle.buffer == ""
    end

    test "several objects in one read are all decoded, in order" do
      {_handle, out} =
        feed(handle(), [
          %{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => "a"}]}
          },
          %{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => "b"}]}
          }
        ])

      assert [{:assistant_text, %{text: "a"}}, {:assistant_text, %{text: "b"}}] = events(out)
    end

    test "an unparseable line is skipped instead of crashing the session" do
      {_handle, out} = feed(handle(), "not json at all\n")
      assert out == []
    end

    test "blank lines are ignored" do
      {_handle, out} = feed(handle(), "\n\n")
      assert out == []
    end
  end

  describe "resume" do
    test "needs a recorded session id and refuses to invent one" do
      assert {:error, reason} = ClaudeCode.resume("a_1", %{})
      assert reason =~ "cc_session_id"
    end

    test "string keys in the header are accepted" do
      # `Store.read_meta/1` atomises with `String.to_existing_atom/1`, and
      # Elixir loads modules lazily — so at boot, before this module is loaded,
      # `:cc_session_id` is not an existing atom and the key comes back as a
      # string. Reading only the atom form reported `no cc_session_id recorded`
      # for a real session whose id was right there in the file.
      assert {:ok, handle} =
               ClaudeCode.resume("a_1", %{"cc_session_id" => @session_id, "cc_cwd" => "/tmp"})

      assert handle.session_id == @session_id
      assert handle.cwd == "/tmp"
      refute handle.first_turn?
    end

    test "loom's instructions are kept for every spawn, fresh or resumed" do
      # `--append-system-prompt` is a flag, not conversation state: a respawn
      # after a release that forgot it would run without them.
      {:ok, fresh} = ClaudeCode.start("a_1", %{instructions: "save files in /x"})
      {:ok, resumed} = ClaudeCode.resume("a_1", %{cc_session_id: @session_id, instructions: "y"})

      assert fresh.instructions == "save files in /x"
      assert resumed.instructions == "y"
    end

    test "a resumed handle does not re-use --session-id" do
      {:ok, handle} = ClaudeCode.resume("a_1", %{cc_session_id: @session_id})
      refute handle.first_turn?
      assert handle.session_id == @session_id
    end

    test "a fresh session gets a valid v4 uuid" do
      # The CLI rejects anything that is not a well-formed uuid.
      {:ok, handle} = ClaudeCode.start("a_1", %{})

      assert handle.session_id =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      {:ok, other} = ClaudeCode.start("a_2", %{})
      refute other.session_id == handle.session_id
      assert handle.first_turn?
    end
  end

  describe "killing a process tree" do
    @tag :tmp_dir
    test "descendants are killed, not orphaned" do
      # This is the bug the whole kill_tree/1 function exists for: `claude` is
      # three processes deep and killing the outermost leaves a 24 MB launcher
      # and a 224 MB runtime behind (measured). A shell nesting two sleeps
      # reproduces the shape without needing the CLI.
      port =
        Port.open({:spawn, "/bin/sh -c 'sh -c \"sleep 30\" & sleep 30'"}, [:binary, :exit_status])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      # Let the children actually exist before we snapshot them.
      Process.sleep(300)

      descendants = pgrep_tree(os_pid)
      assert descendants != [], "test setup produced no child processes"

      ClaudeCode.kill_tree(os_pid)

      for pid <- [os_pid | descendants] do
        refute alive?(pid), "pid #{pid} survived kill_tree/1"
      end

      if Port.info(port) != nil, do: Port.close(port)
    end

    test "killing nothing is not an error" do
      assert ClaudeCode.kill_tree(nil) == :ok
    end
  end

  defp pgrep_tree(pid) do
    case System.cmd("pgrep", ["-P", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        kids = out |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.to_integer/1)
        kids ++ Enum.flat_map(kids, &pgrep_tree/1)

      _ ->
        []
    end
  end

  defp alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end
end
