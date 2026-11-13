defmodule Loom.Agent.ProfilesTest do
  # Swaps the application's home and CLI, which every session reads.
  use ExUnit.Case, async: false

  alias Loom.Agent.Backend.ClaudeCode
  alias Loom.Agent.Profiles

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Application.get_env(:loom, :home)
    agent = Application.get_env(:loom, Loom.Agent, [])

    # A stand-in CLI that records its arguments, one per line, and its stdin.
    cli = Path.join(dir, "claude")

    File.write!(
      cli,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"#{dir}/args\"\ncat > \"#{dir}/stdin.$$\"\n"
    )

    File.chmod!(cli, 0o755)

    Application.put_env(:loom, :home, dir)

    Application.put_env(
      :loom,
      Loom.Agent,
      Keyword.put(agent, :claude_cli, cli)
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

  # Every stdin the stand-in has been given, one file per process.
  defp stdins(dir, lines) do
    read = fn ->
      Path.wildcard(Path.join(dir, "stdin.*"))
      |> Enum.map(&(&1 |> File.read!() |> String.split("\n", trim: true)))
    end

    Enum.find_value(1..100, fn _ ->
      got = read.()
      if got |> List.flatten() |> length() >= lines, do: got, else: Process.sleep(20) && nil
    end) || read.()
  end

  test "lists the json files under profiles/, ignoring odd names", %{tmp_dir: dir} do
    assert Profiles.list() == []

    File.mkdir_p!(Path.join(dir, "profiles"))

    for f <- ["zeta.json", "family-key.json", ".hidden.json", "notes.txt"],
        do: File.write!(Path.join([dir, "profiles", f]), "{}")

    assert Profiles.list() == ["family-key", "zeta"]
    assert {:error, _} = Profiles.path("../etc/passwd")
  end

  test "a session on a profile spawns with --settings", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "profiles"))
    file = Path.join([dir, "profiles", "fam.json"])
    File.write!(file, ~s({"env":{}}))

    {:ok, handle} = ClaudeCode.start("a_1", %{cc_profile: "fam", cc_cwd: dir})
    assert ClaudeCode.persist(handle).cc_profile == "fam"
    {:ok, handle} = ClaudeCode.run_turn(handle, "hi")

    argv = args(dir)
    assert ["--settings", ^file] = Enum.drop_while(argv, &(&1 != "--settings")) |> Enum.take(2)
    ClaudeCode.stop(handle)
  end

  test "the default takes no --settings, --model or --fallback-model", %{tmp_dir: dir} do
    {:ok, handle} = ClaudeCode.start("a_1", %{cc_cwd: dir})
    {:ok, handle} = ClaudeCode.run_turn(handle, "hi")

    argv = args(dir)
    refute "--settings" in argv
    refute "--model" in argv
    refute "--fallback-model" in argv
    ClaudeCode.stop(handle)
  end

  test "a chosen model is spawned with, and persisted", %{tmp_dir: dir} do
    {:ok, handle} = ClaudeCode.start("a_1", %{cc_cwd: dir, model: "haiku"})
    {:ok, handle} = ClaudeCode.run_turn(handle, "hi")

    assert ["--model", "haiku"] = Enum.drop_while(args(dir), &(&1 != "--model")) |> Enum.take(2)
    assert ClaudeCode.persist(handle).model == "haiku"
    ClaudeCode.stop(handle)
  end

  test "a model picked mid-session reaches the live process before the next message",
       %{tmp_dir: dir} do
    {:ok, handle} = ClaudeCode.start("a_1", %{cc_cwd: dir})
    {:ok, handle} = ClaudeCode.run_turn(handle, "hi")
    {:ok, handle} = ClaudeCode.set_model(handle, "sonnet")
    {:ok, handle} = ClaudeCode.run_turn(handle, "again")
    # Unchanged: nothing more to say on the turn after.
    {:ok, handle} = ClaudeCode.run_turn(handle, "and again")

    assert [lines] = stdins(dir, 4)
    assert [hi, control, again, again2] = Enum.map(lines, &Jason.decode!/1)
    assert hi["message"]["content"] == "hi"
    assert control["request"] == %{"subtype" => "set_model", "model" => "sonnet"}
    assert again["message"]["content"] == "again"
    assert again2["message"]["content"] == "and again"
    ClaudeCode.stop(handle)
  end

  test "a profile that has gone missing fails the turn by name", %{tmp_dir: dir} do
    {:ok, handle} = ClaudeCode.start("a_1", %{cc_profile: "gone", cc_cwd: dir})
    assert {:error, reason} = ClaudeCode.run_turn(handle, "hi")
    assert reason =~ "gone"
  end
end
