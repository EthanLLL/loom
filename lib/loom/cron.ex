defmodule Loom.Cron do
  @moduledoc """
  Scheduled prompts: at each match of a cron expression (UTC, see
  `Loom.Cron.Expr`), a fixed prompt is submitted to an existing session, as if
  the user had typed it. The reply lands in that session's transcript like any
  other turn, which is the whole reason this lives in loom rather than in a
  backend's own scheduler.

  One process owns the jobs. `~/.loom/cron.json` is the truth: it is read at
  boot and rewritten on every change, so a crash or a deploy loses nothing but
  the timer, which is rebuilt from the file.

  There is no HTTP API. Jobs are made by an agent — or anyone with a shell — on
  the node itself:

      bin/loom rpc 'IO.inspect(Loom.Cron.add(%{name: "…", cron: "…", target: "a_…", prompt: ~S\"""
      …
      \"""}))'

  and listed in any session with `/cron`.

  - A minute missed while loom was down is skipped, not caught up: the next
    match is counted from boot.
  - A target that is busy gets the prompt the way a typed message would: steered
    into the running turn, or queued.
  """
  use GenServer

  require Logger

  alias Loom.Cron.Expr

  @name __MODULE__
  @persisted ~w(id name cron target prompt created_at last_run_at last_error)a

  # Wake at least this often even with nothing due, so a clock that jumps (a
  # suspended laptop, an NTP step) is noticed within the hour.
  @max_sleep :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Add a job. `attrs` takes `:cron`, `:target` (a session id) and `:prompt`,
  plus an optional `:name`; atom or string keys. Returns `{:ok, job}` — with
  `next_at`, the first time it will fire — or `{:error, reason}`.
  """
  def add(attrs, server \\ @name), do: GenServer.call(server, {:add, attrs})

  @doc "Every job, soonest first, with `next_at` and the target's title."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc "Remove a job by id. `:ok` or `{:error, :not_found}`."
  def delete(id, server \\ @name), do: GenServer.call(server, {:delete, id})

  @doc "Where the jobs are kept."
  def path, do: Application.get_env(:loom, __MODULE__, [])[:path] || default_path()

  defp default_path, do: Path.join(Loom.Agent.Store.home(), "cron.json")

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    now = DateTime.utc_now()
    jobs = path |> load() |> Map.new(&{&1.id, schedule(&1, now)})
    {:ok, arm(%{path: path, jobs: jobs, timer: nil})}
  end

  @impl true
  def handle_call({:add, attrs}, _from, state) do
    case build(attrs) do
      {:ok, job} ->
        job = schedule(job, DateTime.utc_now())
        state = save(put_in(state.jobs[job.id], job))
        {:reply, {:ok, public(job)}, arm(state)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:list, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.sort_by(&(&1.next_at || ~U[9999-01-01 00:00:00Z]), DateTime)
      |> Enum.map(&public/1)

    {:reply, jobs, state}
  end

  def handle_call({:delete, id}, _from, state) do
    if Map.has_key?(state.jobs, id) do
      state = save(%{state | jobs: Map.delete(state.jobs, id)})
      {:reply, :ok, arm(state)}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    due =
      for {id, %{next_at: %DateTime{} = at}} <- state.jobs,
          DateTime.compare(at, now) != :gt,
          do: id

    state =
      Enum.reduce(due, state, fn id, state ->
        job = state.jobs[id]
        fire(job)

        job = %{schedule(job, now) | last_run_at: DateTime.to_iso8601(now)}
        put_in(state.jobs[id], job)
      end)

    state = if due == [], do: state, else: save(state)
    {:noreply, arm(%{state | timer: nil})}
  end

  def handle_info({:delivered, id, result}, state) do
    case state.jobs do
      %{^id => job} ->
        error = if result == :ok, do: nil, else: inspect(result)
        {:noreply, save(put_in(state.jobs[id], %{job | last_error: error}))}

      _ ->
        {:noreply, state}
    end
  end

  # ── Jobs ────────────────────────────────────────────────────────────────

  defp build(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    # A heredoc in `bin/loom rpc` ends with a newline nobody meant to send.
    prompt =
      if is_binary(attrs["prompt"]), do: String.trim(attrs["prompt"]), else: attrs["prompt"]

    target = attrs["target"]

    with {:ok, _} <- Expr.parse(attrs["cron"]) |> describe(),
         :ok <- check_prompt(prompt),
         :ok <- check_target(target) do
      {:ok,
       %{
         id: "c_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false),
         name: name(attrs["name"], prompt),
         cron: attrs["cron"] |> String.split() |> Enum.join(" "),
         target: target,
         prompt: prompt,
         created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         last_run_at: nil,
         last_error: nil
       }}
    end
  end

  defp describe({:ok, expr}) do
    case Expr.next(expr, DateTime.utc_now()) do
      {:ok, _} -> {:ok, expr}
      :none -> {:error, "this cron expression never matches"}
    end
  end

  defp describe(error), do: error

  defp check_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "", do: {:error, "the prompt is empty"}, else: :ok
  end

  defp check_prompt(_other), do: {:error, "a prompt is required"}

  # Only a session that exists: a typo would otherwise sit there firing into
  # nothing. One deleted later shows up as `last_error` instead.
  defp check_target(target) when is_binary(target) do
    case Loom.Agent.Store.read_meta(target) do
      {:ok, _meta} -> :ok
      :error -> {:error, "no session #{inspect(target)}"}
    end
  end

  defp check_target(_other), do: {:error, "a target session id is required"}

  defp name(name, prompt) when name in [nil, ""],
    do: prompt |> String.split("\n") |> hd() |> String.slice(0, 40)

  defp name(name, _prompt), do: to_string(name)

  # `next_at` is derived, never stored: it is recomputed from now at boot,
  # which is what skips the minutes loom was down for.
  defp schedule(job, now) do
    next_at =
      with {:ok, expr} <- Expr.parse(job.cron),
           {:ok, at} <- Expr.next(expr, now) do
        at
      else
        _ -> nil
      end

    Map.put(job, :next_at, next_at)
  end

  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    soonest =
      state.jobs
      |> Map.values()
      |> Enum.map(& &1.next_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

    sleep =
      case soonest do
        nil -> @max_sleep
        at -> at |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(0) |> min(@max_sleep)
      end

    %{state | timer: Process.send_after(self(), :tick, sleep)}
  end

  # Off this process: a submit can wait on a session restoring its backend, and
  # the scheduler must keep time meanwhile.
  defp fire(job) do
    server = self()

    Task.Supervisor.start_child(Loom.Agent.TaskSupervisor, fn ->
      send(server, {:delivered, job.id, deliver(job)})
    end)
  end

  defp deliver(job) do
    with :ok <- ensure_running(job.target),
         {:ok, _} <- Loom.Agent.submit(job.target, job.prompt, origin: "cron") do
      :ok
    end
  catch
    :exit, reason -> {:exit, reason}
  end

  defp ensure_running(id) do
    if Loom.Agent.exists?(id) do
      :ok
    else
      case Loom.Agent.restore_session(id) do
        {:ok, _pid} -> :ok
        error -> error
      end
    end
  end

  defp public(job) do
    title =
      case Loom.Agent.Store.read_meta(job.target) do
        {:ok, meta} -> meta[:title]
        :error -> nil
      end

    Map.put(job, :target_title, title)
  end

  # ── File ────────────────────────────────────────────────────────────────

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"jobs" => jobs}} when is_list(jobs) <- Jason.decode(body) do
      for job <- jobs, is_map(job), is_binary(job["id"]) do
        Map.new(@persisted, &{&1, job[to_string(&1)]})
      end
    else
      {:error, :enoent} ->
        []

      _ ->
        # Moved aside rather than overwritten by the next save: the jobs in it
        # are the user's, and a hand edit gone wrong is worth recovering.
        aside = "#{path}.bad-#{System.os_time(:second)}"
        File.rename(path, aside)
        Logger.error("Loom.Cron cannot read #{path}; moved it to #{aside}")
        []
    end
  end

  defp save(state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
      |> Enum.map(&Map.take(&1, @persisted))

    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(%{jobs: jobs}, pretty: true))
    File.rename!(tmp, state.path)
    state
  end
end
