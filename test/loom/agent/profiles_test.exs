defmodule Loom.Agent.ProfilesTest do
  # Swaps the application's home and CLI, which every session reads.
  use ExUnit.Case, async: false

  alias Loom.Agent.Backend.ClaudeCode
  alias Loom.Agent.Profiles

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Application.get_env(:loom, :home)
    agent = Application.get_env(:loom, Loom.Agent, [])

    # A stand-in CLI that records its arguments, one per line.
    cli = Path.join(dir, "claude")
    File.write!(cli, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"#{dir}/args\"\nsleep 5\n")
    File.chmod!(cli, 0o755)

    Application.put_env(:loom, :home, dir)

    Application.put_env(
      :loom,
      Loom.Agent,
      agent |> Keyword.put(:claude_cli, cli) |> Keyword.put(:claude_fallback_model, "bedrock-x")
    )

    on_exit(fn ->
      if home,
        do: Application.put_env(:loom, :home, home),
        else: Application.delete_env(:loom, :home)

      Application.put_env(:loom, Loom.Agent, agent)
    end)

    :ok
  end

  defp args(dir) do
    file = Path.join(dir, "args")
    Enum.find(1..100, fn _ -> File.exists?(file) or (Process.sleep(20) && false) end)
    file |> File.read!() |> String.split("\n", trim: true)
  end

  test "lists the json files under profiles/, ignoring odd names", %{tmp_dir: dir} do
    assert Profiles.list() == []

    File.mkdir_p!(Path.join(dir, "profiles"))

    for f <- ["zeta.json", "family-key.json", ".hidden.json", "notes.txt"],
        do: File.write!(Path.join([dir, "profiles", f]), "{}")

    assert Profiles.list() == ["family-key", "zeta"]
    assert {:error, _} = Profiles.path("../etc/passwd")
  end

  test "a session on a profile spawns with --settings and no fallback", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "profiles"))
    file = Path.join([dir, "profiles", "fam.json"])
    File.write!(file, ~s({"env":{}}))

    {:ok, handle} = ClaudeCode.start("a_1", %{cc_profile: "fam", cc_cwd: dir})
    assert ClaudeCode.persist(handle).cc_profile == "fam"
    {:ok, handle} = ClaudeCode.run_turn(handle, "hi")

    argv = args(dir)
    assert ["--settings", ^file] = Enum.drop_while(argv, &(&1 != "--settings")) |> Enum.take(2)
    refute "--fallback-model" in argv
    ClaudeCode.stop(handle)
  end

  test "the default keeps the fallback and takes no --settings", %{tmp_dir: dir} do
    {:ok, handle} = ClaudeCode.start("a_1", %{cc_cwd: dir})
    {:ok, handle} = ClaudeCode.run_turn(handle, "hi")

    argv = args(dir)
    assert "--fallback-model" in argv
    refute "--settings" in argv
    ClaudeCode.stop(handle)
  end

  test "a profile that has gone missing fails the turn by name", %{tmp_dir: dir} do
    {:ok, handle} = ClaudeCode.start("a_1", %{cc_profile: "gone", cc_cwd: dir})
    assert {:error, reason} = ClaudeCode.run_turn(handle, "hi")
    assert reason =~ "gone"
  end
end
