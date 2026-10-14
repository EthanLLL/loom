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
      [{pid, _}] -> DynamicSupervisor.terminate_child(Loom.Agent.SessionSupervisor, pid)
      [] -> {:error, :not_found}
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

  defdelegate submit(id, text, opts \\ []), to: Session
  defdelegate interrupt(id), to: Session
  defdelegate drop_queued(id, index), to: Session
  defdelegate rename(id, title), to: Session
  defdelegate attach(id, since_seq \\ 0), to: Session
  defdelegate info(id), to: Session
  defdelegate topic(id), to: Session

  defp safe_info(id) do
    Session.info(id)
  catch
    :exit, _ -> nil
  end
end
