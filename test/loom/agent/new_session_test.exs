defmodule Loom.Agent.NewSessionTest do
  # Not async: sessions and the backend map are global.
  use ExUnit.Case, async: false

  alias Loom.Agent
  alias Loom.BackendStub

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-new-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, Path.join(dir, "sessions"))
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})
    File.mkdir_p!(dir)

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "a file's title and prompt are data: \#{} in them stays text", %{dir: dir} do
    path = Path.join(dir, "req.json")
    title = ~S|搬表 #{System.halt()}|
    File.write!(path, Jason.encode!(%{title: title, prompt: ~S|do #{1 + 1}|}))

    assert {:ok, "a_" <> _ = id} = Agent.new_session_file(path)
    assert BackendStub.await_turn() =~ ~S|do #{1 + 1}|
    assert Agent.info(id).title == title
  end

  test "a bad file is an error, not a session", %{dir: dir} do
    path = Path.join(dir, "bad.json")
    assert {:error, :enoent} = Agent.new_session_file(path)
    File.write!(path, ~s({"title": "x"}))
    assert {:error, "want " <> _} = Agent.new_session_file(path)
    File.write!(path, "{")
    assert {:error, _} = Agent.new_session_file(path)
    assert Agent.list_sessions() == []
  end
end
