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

  @doc "Stop a session and delete its persisted history."
  def delete_session(id) do
    stop_session(id)
    Loom.Agent.Store.delete_session(id)
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
