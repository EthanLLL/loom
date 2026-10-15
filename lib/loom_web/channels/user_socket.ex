defmodule LoomWeb.UserSocket do
  use Phoenix.Socket

  channel "terminal:*", LoomWeb.TerminalChannel
  channel "agent:*", LoomWeb.AgentChannel
  channel "agents", LoomWeb.LobbyChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Loom.Auth.verify_token(token) do
      :ok -> {:ok, socket}
      {:error, _} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
