defmodule Loom.Agent.BackendConfigTest do
  # Points `:home` at a temp dir, which is global.
  use ExUnit.Case, async: false

  alias Loom.Agent.BackendConfig

  setup do
    previous = Application.get_env(:loom, :home)
    home = Path.join(System.tmp_dir!(), "loom-bc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "backends"))
    Application.put_env(:loom, :home, home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:loom, :home, previous),
        else: Application.delete_env(:loom, :home)

      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp write(body), do: File.write!(BackendConfig.path(:kiro), body)

  test "lives under LOOM_HOME/backends, one file per backend", %{home: home} do
    assert BackendConfig.path(:kiro) == Path.join([home, "backends", "kiro.json"])
  end

  test "a missing file is no settings" do
    assert BackendConfig.get(:kiro) == %{model: nil, effort: nil, args: [], env: %{}}
  end

  test "every key is read" do
    write(~s({"model": " claude-opus-5.5 ", "effort": "high", "args": ["-v"], "env": {"A": "1"}}))

    assert BackendConfig.get(:kiro) == %{
             model: "claude-opus-5.5",
             effort: "high",
             args: ["-v"],
             env: %{"A" => "1"}
           }
  end

  test "it is read afresh each time" do
    write(~s({"model": "a"}))
    assert BackendConfig.get(:kiro).model == "a"
    write(~s({"model": "b"}))
    assert BackendConfig.get(:kiro).model == "b"
  end

  test "a broken file is ignored, not fatal" do
    write("{not json")
    assert BackendConfig.get(:kiro) == %{model: nil, effort: nil, args: [], env: %{}}
    write("[1, 2]")
    assert BackendConfig.get(:kiro).model == nil
  end

  test "values of the wrong type are dropped one by one" do
    write(~s({"model": 5, "effort": "", "args": "nope", "env": {"A": "1", "B": 2}}))
    assert BackendConfig.get(:kiro) == %{model: nil, effort: nil, args: [], env: %{"A" => "1"}}
  end
end
