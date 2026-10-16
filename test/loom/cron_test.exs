defmodule Loom.CronTest do
  # Not async: sessions and the backend map are global.
  use ExUnit.Case, async: false

  alias Loom.Agent
  alias Loom.BackendStub
  alias Loom.Cron

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-cron-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, Path.join(dir, "sessions"))
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(dir)
    end)

    path = Path.join(dir, "cron.json")
    {:ok, path: path, cron: start_cron(path)}
  end

  defp start_cron(path) do
    name = :"cron_#{System.unique_integer([:positive])}"
    start_supervised!({Cron, name: name, path: path}, id: name)
    name
  end

  defp new_session do
    id = "a_c#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.start_session(id, backend: :claude_code)
    id
  end

  # Make the job due now and let the scheduler notice.
  defp fire_now(cron, id) do
    :sys.replace_state(cron, fn state ->
      put_in(state.jobs[id].next_at, DateTime.add(DateTime.utc_now(), -1))
    end)

    send(cron, :tick)
    :sys.get_state(cron)
  end

  test "a job is validated, saved, and listed with when it fires next", %{cron: cron, path: path} do
    target = new_session()

    assert {:error, "bad hour field: \"25\""} =
             Cron.add(%{cron: "0 25 * * *", target: target, prompt: "x"}, cron)

    assert {:error, "no session \"a_nope\""} =
             Cron.add(%{cron: "0 9 * * *", target: "a_nope", prompt: "x"}, cron)

    assert {:error, "the prompt is empty"} =
             Cron.add(%{cron: "0 9 * * *", target: target, prompt: "  "}, cron)

    assert {:ok, job} =
             Cron.add(%{"cron" => " 0  9 * * * ", "target" => target, "prompt" => "日报\n细节"}, cron)

    assert job.cron == "0 9 * * *"
    assert job.name == "日报"
    assert %DateTime{hour: 9, minute: 0} = job.next_at

    assert [listed] = Cron.list(cron)
    assert listed.id == job.id

    # The file holds the job, not the derived schedule.
    assert %{"jobs" => [saved]} = path |> File.read!() |> Jason.decode!()
    assert saved["prompt"] == "日报\n细节"
    refute Map.has_key?(saved, "next_at")
  end

  test "the file is the truth across a restart", %{cron: cron, path: path} do
    target = new_session()
    {:ok, job} = Cron.add(%{cron: "*/5 * * * *", target: target, prompt: "x"}, cron)

    again = start_cron(path)
    assert [%{id: id, next_at: %DateTime{}}] = Cron.list(again)
    assert id == job.id

    assert :ok = Cron.delete(job.id, again)
    assert {:error, :not_found} = Cron.delete(job.id, again)
    assert [] = Cron.list(start_cron(path))
  end

  test "an unreadable file is moved aside, not overwritten", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not json")

    assert [] = Cron.list(start_cron(path))
    refute File.exists?(path)
    assert [_aside] = Path.wildcard(path <> ".bad-*")
  end

  test "a due job is submitted to its session as a cron message", %{cron: cron} do
    target = new_session()
    {:ok, job} = Cron.add(%{cron: "0 9 * * *", target: target, prompt: "看一下 CI"}, cron)

    fire_now(cron, job.id)
    assert BackendStub.await_turn() == "看一下 CI"

    {:ok, snapshot} = Agent.attach(target, 0)
    assert [%{kind: :user, payload: %{origin: "cron"}} | _] = snapshot.events

    [listed] = Cron.list(cron)
    assert listed.last_run_at
    assert DateTime.compare(listed.next_at, DateTime.utc_now()) == :gt
  end

  test "a target that is gone is recorded, not retried in a loop", %{cron: cron} do
    target = new_session()
    {:ok, job} = Cron.add(%{cron: "0 9 * * *", target: target, prompt: "x"}, cron)
    Agent.delete_session(target)

    fire_now(cron, job.id)
    Process.sleep(100)

    assert [%{last_error: error}] = Cron.list(cron)
    assert error =~ "no_such_session"
    BackendStub.refute_turn()
  end
end
