defmodule LoomWeb.DevicePortSocket do
  @moduledoc """
  A port on a device's loopback, relayed: a WebSocket whose bytes go to and
  from it through the device's `LoomWeb.NodeChannel` (`tcp_open`, `tcp_in`;
  back `tcp_out`). For when the browser cannot reach the device directly
  (`LoomWeb.DevicesController.rtc/2`). Connect uses it for the Mac's screen:
  loom-mac-screen's H.264, or VNC from Screen Sharing. Bytes go through
  untouched; the page speaks the protocol.

  The channel monitors this process and tells the device to close the port
  when it goes; this one closes, saying why, when the device does or drops.
  """
  @behaviour WebSock

  # A device whose loom-node predates tunnels ignores the request.
  @open_timeout 10_000

  @impl true
  def init({channel, port}) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Process.monitor(channel)
    send(channel, {:node_send, self(), id, "tcp_open", %{"port" => port}})
    Process.send_after(self(), :open_timeout, @open_timeout)
    {:ok, %{channel: channel, id: id, opened: false}}
  end

  # Sent on at once: the device drops what arrives before the port is open,
  # and neither VNC nor loom-mac-screen has the viewer speak first.
  @impl true
  def handle_in({data, opcode: :binary}, state) do
    send(
      state.channel,
      {:node_send, self(), state.id, "tcp_in", %{"data" => Base.encode64(data)}}
    )

    {:ok, state}
  end

  def handle_in(_text, state), do: {:ok, state}

  @impl true
  def handle_info({:node_reply, id, event, payload}, %{id: id} = state) do
    case event do
      "tcp_out" -> {:push, {:binary, Base.decode64!(payload["data"])}, state}
      "tcp_opened" -> {:ok, %{state | opened: true}}
      "tcp_closed" -> {:stop, :normal, state}
      "error" -> close(state, payload["message"] || "the device refused")
      _ -> {:ok, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{channel: pid} = state),
    do: close(state, "the device went offline")

  def handle_info(:open_timeout, %{opened: false} = state),
    do: close(state, "the device did not answer; its loom-node may need updating")

  def handle_info(_, state), do: {:ok, state}

  # The reason goes in the close frame, where the page reads it; a close
  # reason is at most 123 bytes.
  defp close(state, message),
    do: {:stop, :normal, {1011, binary_part(message, 0, min(byte_size(message), 123))}, state}
end
