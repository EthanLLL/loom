defmodule Loom.Agent.Bootstrap do
  @moduledoc """
  Brings every persisted session's process back up at boot.

  Startup reads only the headers, which is cheap, and starts a process for each
  session. Each one reattaches to its backend conversation — `--resume` for
  Claude Code, `thread/resume` for Codex — so a session is usable the moment the
  node is up, without waiting for a client.

  A session that was mid-turn comes back `:interrupted` rather than resuming:
  the turn belonged to a child process that died with the node. See
  `Loom.Agent.Session`.

  Restoring every session eagerly costs little: the transcript is capped and no
  conversation history is held in memory any more. The one real cost is on the
  Codex side, where each session claims its thread's writer lock — which is also
  what clears a lock left stale by an unclean shutdown.

  Runs from `handle_continue/2` so a slow disk cannot hold up the supervision
  tree, and failures are logged per session rather than taking the node down —
  one unreadable session directory must not stop the others from coming back.
  """
  use GenServer, restart: :transient

  require Logger

  alias Loom.Agent
  alias Loom.Agent.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, true) do
      {:ok, %{}, {:continue, :restore}}
    else
      :ignore
    end
  end

  @impl true
  def handle_continue(:restore, state) do
    metas = Store.list_metas()

    restored =
      Enum.count(metas, fn meta ->
        case Agent.start_session(meta[:id], restore: true) do
          {:ok, _pid} ->
            true

          {:error, reason} ->
            Logger.warning("Loom.Agent cannot restore #{meta[:id]}: #{inspect(reason)}")
            false
        end
      end)

    if metas != [] do
      Logger.info("Loom.Agent restored #{restored}/#{length(metas)} session(s)")
    end

    {:noreply, state}
  end
end
