defmodule Loom.Agent.Backend.KiroPortTest do
  @moduledoc """
  The Kiro adapter end to end over a real port, against a stand-in `kiro-cli`:
  a shell script that plays the agent side of ACP line by line. The adapter's
  request ids are sequential, so the script can answer them by number.

  `kiro_test.exs` covers the translation as a pure function; this covers what
  only a process shows: the handshake actually happening, what goes on the
  wire, the engine's requests being answered, interrupt, a failed load, and
  the process dying under a turn.
  """
  # Points the app env at the stand-in, which is global.
  use ExUnit.Case, async: false

  alias Loom.Agent.Backend.Kiro

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:loom, Loom.Agent, [])
    previous_home = Application.get_env(:loom, :home)
    # No model is picked, so the ids below hold: initialize, new/load,
    # set_mode, prompt.
    Application.put_env(:loom, :home, Path.join(dir, "home"))

    on_exit(fn ->
      Application.put_env(:loom, Loom.Agent, previous)

      if previous_home,
        do: Application.put_env(:loom, :home, previous_home),
        else: Application.delete_env(:loom, :home)
    end)

    # As in `Loom.Agent.Session`: a CLI that exits must not take the owner down.
    Process.flag(:trap_exit, true)
    :ok
  end

  # Installs `body` as the kiro-cli Loom runs. `say` lines are JSON written as
  # Elixir maps; `take` reads one line from the adapter into the log.
  defp fake_cli(dir, steps) do
    # The script single-quotes paths, and the tmp dir is named after the test.
    if dir =~ "'", do: raise("test names here must not contain an apostrophe")
    log = Path.join(dir, "in.jsonl")

    body =
      Enum.map_join(steps, "\n", fn
        :take -> ~s(IFS= read -r line; printf '%s\\n' "$line" >> '#{log}')
        {:say, message} -> "printf '%s\\n' '#{Jason.encode!(Map.put(message, "jsonrpc", "2.0"))}'"
        {:exit, status} -> "exit #{status}"
        :linger -> "sleep 30"
      end)

    cli = Path.join(dir, "kiro-cli")
    File.write!(cli, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(cli, 0o755)

    config = Application.get_env(:loom, Loom.Agent, [])
    Application.put_env(:loom, Loom.Agent, Keyword.put(config, :kiro_cli, cli))
    log
  end

  defp sent(log) do
    log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp reply(id, result), do: {:say, %{"id" => id, "result" => result}}

  defp update(update),
    do:
      {:say,
       %{
         "method" => "session/update",
         "params" => %{"sessionId" => "sess_fake", "update" => update}
       }}

  defp chunk(text),
    do:
      update(%{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text},
        "_meta" => %{"kiro" => %{"replayId" => "r1"}}
      })

  # Feeds port messages to decode/2 until `done?` holds on the handle and
  # what has come out so far; returns both.
  defp pump(handle, done?, out \\ [], deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    if done?.(handle, out) do
      {handle, out}
    else
      receive do
        message ->
          case Kiro.decode(handle, message) do
            {:ok, handle, produced} -> pump(handle, done?, out ++ produced, deadline)
            :ignore -> pump(handle, done?, out, deadline)
          end
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("timed out; so far: #{inspect(out, limit: 20)}")
      end
    end
  end

  defp events(out), do: for({:event, kind, payload} <- out, do: {kind, payload})

  defp ended?(out),
    do: Enum.any?(events(out), fn {kind, _} -> kind in [:turn_done, :turn_failed] end)

  test "a turn from spawn to end, answering the engine on the way", %{tmp_dir: dir} do
    log =
      fake_cli(dir, [
        :take,
        reply(1, %{"protocolVersion" => 1}),
        :take,
        reply(2, %{"sessionId" => "sess_fake", "modes" => %{}}),
        :take,
        reply(3, %{}),
        :take,
        chunk("Hel"),
        chunk("lo"),
        update(%{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "kind" => "execute",
          "status" => "pending",
          "rawInput" => %{"command" => "ls"}
        }),
        {:say,
         %{
           "id" => "perm1",
           "method" => "session/request_permission",
           "params" => %{
             "sessionId" => "sess_fake",
             "toolCall" => %{"toolCallId" => "t1"},
             "options" => [
               %{"optionId" => "accept", "kind" => "allow_once"},
               %{"optionId" => "reject", "kind" => "reject_once"}
             ]
           }
         }},
        :take,
        update(%{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "t1",
          "status" => "completed",
          "rawOutput" => %{"output" => "a b\n"}
        }),
        reply(4, %{"stopReason" => "end_turn"}),
        :linger
      ])

    {:ok, handle} = Kiro.start("a_1", %{instructions: "LOOM SAYS HI"})
    {:ok, handle} = Kiro.run_turn(handle, "hello")
    {handle, out} = pump(handle, fn _h, out -> ended?(out) end)

    assert [
             {:status, %{status: :running, backend_ref: "sess_fake"}},
             {:assistant_text, %{text: "Hello"}},
             {:tool_use, %{id: "t1", name: "shell", input: %{"command" => "ls"}}},
             {:tool_result, %{id: "t1", status: :ok, output: "a b\n"}},
             {:turn_done, %{stop_reason: "end_turn"}}
           ] = events(out)

    assert Kiro.persist(handle).kiro_session_id == "sess_fake"

    [init, new, mode, prompt, permission] = sent(log)
    assert init["method"] == "initialize"
    assert get_in(init, ["params", "clientCapabilities", "_meta", "kiro", "userInput"]) == true

    # Loom's instructions are the session's own agent, written before the
    # spawn and selected as its mode.
    assert new["method"] == "session/new"
    refute Map.has_key?(new["params"], "_meta")
    assert mode["method"] == "session/set_mode"
    assert mode["params"] == %{"sessionId" => "sess_fake", "modeId" => "loom-a_1"}
    assert File.read!(Kiro.agent_path("a_1")) =~ "---\nLOOM SAYS HI\n"

    assert prompt["method"] == "session/prompt"
    assert [%{"type" => "text", "text" => "hello"}] = prompt["params"]["prompt"]

    assert permission["id"] == "perm1"
    assert permission["result"]["outcome"] == %{"outcome" => "selected", "optionId" => "accept"}

    Kiro.stop(handle)
    refute File.exists?(Kiro.agent_path("a_1"))
  end

  test "an interrupt is a cancel, and the cancelled reply ends nothing", %{tmp_dir: dir} do
    log =
      fake_cli(dir, [
        :take,
        reply(1, %{}),
        :take,
        reply(2, %{"sessionId" => "sess_fake", "modes" => %{}}),
        :take,
        reply(3, %{}),
        :take,
        chunk("working"),
        :take,
        reply(4, %{"stopReason" => "cancelled"}),
        :linger
      ])

    {:ok, handle} = Kiro.start("a_1", %{})
    {:ok, handle} = Kiro.run_turn(handle, "long job")

    {handle, out} =
      pump(handle, fn _h, out -> Enum.any?(out, &match?({:delta, %{type: :text}}, &1)) end)

    assert [{:status, %{status: :running}}] = events(out)

    {:ok, handle} = Kiro.interrupt(handle)
    {handle, out} = pump(handle, fn h, _out -> h.prompt_id == nil end)

    # The streamed text is kept; no ending is reported: the session reports
    # the stop itself.
    refute ended?(out)

    assert [%{"method" => "session/cancel", "params" => %{"sessionId" => "sess_fake"}}] =
             sent(log) |> Enum.drop(4)

    Kiro.stop(handle)
  end

  test "a conversation that cannot be loaded is opened afresh, keeping the turn", %{tmp_dir: dir} do
    log =
      fake_cli(dir, [
        :take,
        reply(1, %{}),
        :take,
        {:say, %{"id" => 2, "error" => %{"code" => -32002, "message" => "Session not found"}}},
        :take,
        reply(3, %{"sessionId" => "sess_new", "modes" => %{}}),
        :take,
        reply(4, %{}),
        :take,
        reply(5, %{"stopReason" => "end_turn"}),
        :linger
      ])

    {:ok, handle} = Kiro.resume("a_1", %{kiro_session_id: "sess_gone"})
    {:ok, handle} = Kiro.run_turn(handle, "still there?")
    {handle, out} = pump(handle, fn _h, out -> ended?(out) end)

    assert {:turn_done, _} = List.last(events(out))
    assert Kiro.persist(handle).kiro_session_id == "sess_new"

    [_init, load, new, _mode, prompt] = sent(log)
    assert load["method"] == "session/load"
    assert load["params"]["sessionId"] == "sess_gone"
    assert get_in(load, ["params", "_meta", "kiro", "noReplay"]) == true
    assert new["method"] == "session/new"
    assert prompt["params"]["sessionId"] == "sess_new"

    Kiro.stop(handle)
  end

  test "kiro-cli dying under a turn fails it", %{tmp_dir: dir} do
    fake_cli(dir, [
      :take,
      reply(1, %{}),
      :take,
      reply(2, %{"sessionId" => "sess_fake", "modes" => %{}}),
      :take,
      chunk("half an ans"),
      {:exit, 3}
    ])

    {:ok, handle} = Kiro.start("a_1", %{})
    {:ok, handle} = Kiro.run_turn(handle, "go")
    {handle, out} = pump(handle, fn _h, out -> ended?(out) end)

    assert [
             {:status, %{status: :running}},
             {:assistant_text, %{text: "half an ans"}},
             {:turn_failed, %{reason: reason}}
           ] = events(out)

    assert reason =~ "status 3"
    assert handle.port == nil
  end

  test "a missing kiro-cli is an error, not a crash", %{tmp_dir: dir} do
    config = Application.get_env(:loom, Loom.Agent, [])
    Application.put_env(:loom, Loom.Agent, Keyword.put(config, :kiro_cli, Path.join(dir, "nope")))

    {:ok, handle} = Kiro.start("a_1", %{})
    assert {:error, reason} = Kiro.run_turn(handle, "hi")
    assert reason =~ "could not find"
  end
end
