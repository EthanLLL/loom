defmodule Loom.Terminal do
  @moduledoc "Entry point for managing terminal sessions."

  alias Loom.Terminal.Session

  @doc "Start a new session (or return the existing one for `id`)."
  def start_session(id, opts \\ []) do
    spec = {Session, [{:id, id} | opts]}

    case DynamicSupervisor.start_child(Loom.Terminal.SessionSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Whether a session with `id` is currently alive."
  def exists?(id) do
    case Registry.lookup(Loom.Terminal.Registry, id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @doc "Stop a session, terminating its shell/PTY."
  def stop_session(id) do
    case Registry.lookup(Loom.Terminal.Registry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Loom.Terminal.SessionSupervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "List metadata for all live sessions, oldest first."
  def list_sessions do
    Loom.Terminal.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(&safe_info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.created_at)
  end

  defdelegate subscribe(id, pid, size \\ nil), to: Session
  defdelegate send_input(id, pid, data), to: Session
  defdelegate resize(id, pid, cols, rows), to: Session
  defdelegate info(id), to: Session

  defp safe_info(id) do
    Session.info(id)
  catch
    :exit, _ -> nil
  end
end
