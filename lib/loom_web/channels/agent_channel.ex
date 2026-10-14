defmodule LoomWeb.AgentChannel do
  @moduledoc """
  One channel per *attachment* to an agent session, not per session — several
  devices join `agent:<id>` at once and all of them both receive and send.

  Client → server:
    - "submit"    : %{"text" => _, "client_msg_id" => _}
    - "interrupt" : %{}

  Server → client:
    - "event" : one transcript event, `%{seq:, at:, kind:, payload:}`

  Join replies with everything after the client's `since_seq`, so a phone
  opening cold passes 0 and gets the transcript, while a laptop reconnecting
  passes its last seq and gets only the gap.

  Nothing here holds session state: the `Loom.Agent.Session` process owns it and
  broadcasts on PubSub, so a channel crash or a closed tab costs nothing.
  """
  use Phoenix.Channel

  alias Loom.Agent

  @impl true
  def join("agent:" <> id, params, socket) do
    if Agent.exists?(id) do
      since_seq = params |> Map.get("since_seq", 0) |> normalize_seq()
      device = Map.get(params, "device", "unknown")

      {:ok, snapshot} = Agent.attach(id, since_seq)

      # Subscribe after the snapshot is taken. The session serialises both in
      # its mailbox, so an event emitted between the two arrives as a broadcast
      # with a seq above `last_seq` — it can be appended, not lost.
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))

      {:ok, snapshot, socket |> assign(:session_id, id) |> assign(:device, device)}
    else
      {:error, %{reason: "unknown_session"}}
    end
  end

  @impl true
  def handle_in("submit", %{"text" => text} = params, socket) when is_binary(text) do
    case Agent.submit(socket.assigns.session_id, text,
           origin: socket.assigns.device,
           client_msg_id: Map.get(params, "client_msg_id")
         ) do
      {:ok, disposition} -> {:reply, {:ok, %{status: disposition}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("submit", _params, socket) do
    {:reply, {:error, %{reason: "submit requires a `text` string"}}, socket}
  end

  def handle_in("interrupt", _params, socket) do
    # Queued messages survive an interrupt on purpose: stopping the agent must
    # not immediately start something else. The user continues by typing, which
    # sends the parked messages along with the new one.
    case Agent.interrupt(socket.assigns.session_id) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("drop_queued", %{"index" => index}, socket) when is_integer(index) do
    case Agent.drop_queued(socket.assigns.session_id, index) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("rename", %{"title" => title}, socket) when is_binary(title) do
    case Agent.rename(socket.assigns.session_id, title) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:agent_event, _id, event}, socket) do
    push(socket, "event", event)
    {:noreply, socket}
  end

  # Transient streaming chunks. No `seq`, not persisted, never replayed: a
  # client appends them to the placeholder named by `block_id` and throws the
  # buffer away when the authoritative event for that `block_id` arrives (or on
  # reconnect). That is what makes a dropped stream cost nothing.
  def handle_info({:agent_delta, _id, delta}, socket) do
    push(socket, "delta", delta)
    {:noreply, socket}
  end

  defp normalize_seq(seq) when is_integer(seq) and seq >= 0, do: seq
  defp normalize_seq(_), do: 0
end
