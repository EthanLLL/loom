defmodule LoomWeb.VncSocket do
  @moduledoc """
  The user's view of loom's own browser: a WebSocket carrying VNC (RFB) to and
  from x11vnc on `127.0.0.1:5900`, which shows the Chromium that
  `rel/browser/loom-browser.sh` keeps running. Bytes go through untouched, the
  way websockify would pass them; noVNC on the page speaks the protocol.

  x11vnc has no password and listens on loopback only, so this socket is the
  one way in, and `LoomWeb.BrowserController` lets it open only with a valid
  login token.
  """
  @behaviour WebSock

  @port 5900

  @impl true
  def init(_) do
    case :gen_tcp.connect({127, 0, 0, 1}, @port, [:binary, active: :once, nodelay: true], 3_000) do
      {:ok, vnc} -> {:ok, vnc}
      {:error, reason} -> {:stop, {:shutdown, reason}, {1011, "the browser is not running"}, nil}
    end
  end

  @impl true
  def handle_in({data, opcode: :binary}, vnc) do
    :ok = :gen_tcp.send(vnc, data)
    {:ok, vnc}
  end

  def handle_in(_text, vnc), do: {:ok, vnc}

  # One read at a time: the next is asked for only once this one has gone out,
  # so a slow client holds x11vnc back rather than filling this mailbox.
  @impl true
  def handle_info({:tcp, vnc, data}, vnc) do
    :inet.setopts(vnc, active: :once)
    {:push, {:binary, data}, vnc}
  end

  def handle_info({:tcp_closed, vnc}, vnc), do: {:stop, :normal, vnc}
  def handle_info({:tcp_error, vnc, _}, vnc), do: {:stop, :normal, vnc}
  def handle_info(_, vnc), do: {:ok, vnc}

  @impl true
  def terminate(_reason, nil), do: :ok
  def terminate(_reason, vnc), do: :gen_tcp.close(vnc)
end
