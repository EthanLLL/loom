defmodule LoomWeb.LobbyChannel do
  @moduledoc """
  The session list, pushed instead of polled. The topic is `agents`.

  Server → client:
    - join reply : `%{sessions: [summary], nodes: [device]}`, both whole lists
    - "session"  : one summary, whenever that session's header changes
    - "removed"  : `%{id: _}`, when a session is stopped or deleted
    - "node"     : one device (`Loom.Nodes`), when it is added, renamed, or
                   comes online or goes offline
    - "node_removed" : `%{id: _}`, when a device is removed
    - "apps"     : `%{apps: [app]}`, the whole list (`Loom.Apps.list/0`) on any
                   change; also in the join reply

  Client → server:
    - "watching" : `%{endpoint:, session:}`, which session this device is
                   showing (`nil` when none, or the app is hidden), so its
                   notifications for that session are held back; see
                   `Loom.Push`
    - "search"   : `%{q:}`, full-text search of every transcript; replied to
                   with `%{hits: [...]}` (`Loom.Search.content/1`) or
                   `%{reason:}` — `"no_rg"` when ripgrep is not installed. A new one
                   cancels the one still running.

  A summary is what `GET /api/agents` returns for one session, plus `seq`. The
  client keeps whichever copy of a session has the higher `seq`: the channel is
  subscribed before the list is read, so a summary broadcast in between arrives
  *after* the join reply despite being older than it.

  A reconnect rejoins and gets the whole list again, so nothing missed while
  offline needs replaying.
  """
  use Phoenix.Channel

  alias Loom.Agent

  @impl true
  def join("agents", _params, socket) do
    # Already subscribed to "agents" by `Phoenix.Channel.Server` — the session
    # broadcasts on exactly this topic, so no extra subscribe (it would deliver
    # everything twice; see `LoomWeb.AgentChannel`).
    {:ok, %{sessions: Agent.list_sessions(), nodes: Loom.Nodes.list(), apps: Loom.Apps.list()},
     socket}
  end

  @impl true
  def handle_in("watching", %{"endpoint" => endpoint} = params, socket)
      when is_binary(endpoint) do
    Loom.Push.watching(endpoint, params["session"], self())
    {:noreply, socket}
  end

  # Off the channel process, so a slow search never holds up the list's own
  # pushes; replied to from there by ref. Typing sends one per pause, and only
  # the newest is wanted, so the one before it is killed (its rg goes with it).
  def handle_in("search", %{"q" => q}, socket) when is_binary(q) do
    if pid = socket.assigns[:search], do: Process.exit(pid, :kill)
    ref = socket_ref(socket)

    pid =
      spawn(fn ->
        case Loom.Search.content(q) do
          {:ok, hits} -> reply(ref, {:ok, %{hits: hits}})
          # A plain word the browser can tell apart: "no_rg" means content
          # search is not available here, not that it failed.
          {:error, :no_rg} -> reply(ref, {:error, %{reason: "no_rg"}})
          {:error, reason} -> reply(ref, {:error, %{reason: inspect(reason)}})
        end
      end)

    {:noreply, assign(socket, :search, pid)}
  end

  @impl true
  def handle_info({:agent_summary, summary}, socket) do
    push(socket, "session", summary)
    {:noreply, socket}
  end

  def handle_info({:agent_removed, id}, socket) do
    push(socket, "removed", %{id: id})
    {:noreply, socket}
  end

  def handle_info({:node_summary, node}, socket) do
    push(socket, "node", node)
    {:noreply, socket}
  end

  def handle_info({:apps, apps}, socket) do
    push(socket, "apps", %{apps: apps})
    {:noreply, socket}
  end

  def handle_info({:node_removed, id}, socket) do
    push(socket, "node_removed", %{id: id})
    {:noreply, socket}
  end
end
