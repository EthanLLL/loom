defmodule Loom.Agent do
  @moduledoc "Entry point for managing agent sessions."

  alias Loom.Agent.Session

  @doc """
  Start a new agent session (or return the existing one for `id`).

  `:backend` is required and permanent: `:claude_code` or `:codex`. The
  conversation lives in that engine's own store, so there is nothing to migrate
  if it changes.
  """
  def start_session(id, opts \\ []) do
    spec = {Session, [{:id, id} | opts]}

    case DynamicSupervisor.start_child(Loom.Agent.SessionSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Start a fresh session titled `title` and submit `prompt` to it, as a person
  starting a new chat would; returns `{:ok, id}`. `:backend` defaults to
  `:claude_code`.
  """
  def new_session(title, prompt, opts \\ []) do
    id = "a_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    backend = Keyword.get(opts, :backend, :claude_code)

    with {:ok, _} <- start_session(id, backend: backend, title: title),
         {:ok, _} <- submit(id, prompt, Keyword.take(opts, [:origin])) do
      {:ok, id}
    end
  end

  @doc """
  `new_session/3` with its arguments in a JSON file — `{"title", "prompt"}`,
  optionally `"backend": "codex"` — for programs: an app's job hands work to
  an agent with `bin/loom rpc 'Loom.Agent.new_session_file("…")'`. Text spliced
  into rpc code instead would run any `\#{…}` in it as Elixir.
  """
  def new_session_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"title" => title, "prompt" => prompt} = req}
         when is_binary(title) and is_binary(prompt) <- Jason.decode(body) do
      backend = if req["backend"] == "codex", do: :codex, else: :claude_code
      new_session(title, prompt, backend: backend, origin: "app")
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, Exception.message(e)}
      {:error, reason} -> {:error, reason}
      _ -> {:error, ~s(want {"title": "…", "prompt": "…"})}
    end
  end

  @doc "Whether a session with `id` is currently alive."
  def exists?(id) do
    case Registry.lookup(Loom.Agent.Registry, id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @doc """
  Restore a persisted session's process from disk.

  A session that was mid-turn when the node stopped comes back `:interrupted`
  with its queue intact: a backend turn dies with this node and cannot be
  rejoined, and re-sending would duplicate a message the backend already has.
  """
  def restore_session(id), do: start_session(id, restore: true)

  @doc """
  Stop a session's process. Its history stays on disk and can be restored —
  use `delete_session/1` to actually discard it.
  """
  def stop_session(id) do
    case Registry.lookup(Loom.Agent.Registry, id) do
      [{pid, _}] ->
        result = DynamicSupervisor.terminate_child(Loom.Agent.SessionSupervisor, pid)
        Phoenix.PubSub.broadcast(Loom.PubSub, lobby_topic(), {:agent_removed, id})
        result

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Stop a session and move its persisted history to the trash."
  def delete_session(id) do
    stop_session(id)
    Loom.Agent.Store.delete_session(id)
  end

  @doc """
  Move or rename a directory of the session list: every session whose path is
  `from` or under it gets `from` swapped for `to`. Into a directory that already
  exists is a merge, as with S3 prefixes. See `Loom.Agent.Directory`.

  Not atomic across sessions — each header is its own file — but a move that
  stops halfway leaves every session somewhere real, and running it again
  finishes it.
  """
  def move_directory(from, to) do
    alias Loom.Agent.Directory

    with {:ok, from} <- Directory.normalize(from),
         {:ok, to} <- Directory.normalize(to),
         :ok <- movable(from, to) do
      for %{id: id, directory: dir} <- list_sessions(),
          {:ok, new} <- [Directory.rebase(dir, from, to)],
          do: Session.move(id, new)

      :ok
    end
  end

  defp movable("", _to), do: {:error, :root}

  defp movable(from, to) do
    if Loom.Agent.Directory.within?(to, from) and to != from,
      do: {:error, :into_itself},
      else: :ok
  end

  @doc "List metadata for all live sessions, oldest first."
  def list_sessions do
    Loom.Agent.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(&safe_info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.created_at)
  end

  @doc """
  List every persisted session's header, live or not.

  Reads only the headers, so it stays cheap regardless of transcript size.
  """
  def list_persisted, do: Loom.Agent.Store.list_metas()

  @doc """
  Make both backends pick up changed config — settings, MCP servers, skills —
  without restarting loom. What `/reload` does, from any session.

  Every session is told to let its backend process go (now if idle, after its
  turn if not), which is what Claude Code needs: the next turn starts a fresh
  `claude --resume`. Codex has one shared app-server, which restarts itself once
  no codex turn is running. Fire and forget: nothing waits on either.
  """
  def reload_backends do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Loom.Agent.SessionSupervisor),
        is_pid(pid),
        do: send(pid, :reload_backend)

    Loom.Agent.Codex.Server.reload()
    :ok
  end

  defdelegate submit(id, text, opts \\ []), to: Session
  defdelegate interrupt(id), to: Session
  defdelegate drop_queued(id, index), to: Session
  defdelegate rename(id, title), to: Session
  defdelegate move(id, directory), to: Session
  defdelegate attach(id, since_seq \\ 0), to: Session
  defdelegate info(id), to: Session
  defdelegate topic(id), to: Session

  @doc """
  The topic the session list lives on.

  Each session broadcasts `{:agent_summary, info}` whenever its header changes —
  status, title, queue, usage — and `stop_session/1` broadcasts
  `{:agent_removed, id}`. That is everything a sidebar needs, so it never has to
  poll.
  """
  def lobby_topic, do: "agents"

  @doc """
  The topic turn ends are announced on, for `Loom.Push`: `{:turn_ended, id,
  %{title:, outcome:}}` once a turn is over and nothing queued follows it.
  `outcome` is `{:ok, last_reply_or_nil}` or `{:error, message}`.
  """
  def turns_topic, do: "turns"

  defp safe_info(id) do
    Session.info(id)
  catch
    :exit, _ -> nil
  end
end
