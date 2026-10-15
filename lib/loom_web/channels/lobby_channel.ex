defmodule LoomWeb.LobbyChannel do
  @moduledoc """
  The session list, pushed instead of polled. The topic is `agents`.

  Server → client:
    - join reply : `%{sessions: [summary]}`, the whole list
    - "session"  : one summary, whenever that session's header changes
    - "removed"  : `%{id: _}`, when a session is stopped or deleted

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
    {:ok, %{sessions: Agent.list_sessions()}, socket}
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
end
