defmodule LoomWeb.NodeSocket do
  @moduledoc """
  Where `loom-node daemon` connects, apart from the browser's `LoomWeb.UserSocket`:
  a device holds a device token, not a login, and must never reach a session
  or a terminal. Its one channel is `LoomWeb.NodeChannel`.
  """
  use Phoenix.Socket

  channel "node", LoomWeb.NodeChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Loom.Nodes.authenticate(token) do
      {:ok, id} -> {:ok, assign(socket, :node_id, id)}
      :error -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "node_socket:#{socket.assigns.node_id}"
end
