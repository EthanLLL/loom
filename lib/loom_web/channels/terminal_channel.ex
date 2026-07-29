defmodule LoomWeb.TerminalChannel do
  @moduledoc """
  One channel == one terminal session. The topic is `terminal:<id>`.

  Client → server:
    - binary frames  : raw keystrokes → PTY stdin
    - "resize" event : %{"cols" => c, "rows" => r}

  Server → client:
    - binary frames  : raw PTY output → xterm.js
  """
  use Phoenix.Channel

  alias Loom.Terminal

  @impl true
  def join("terminal:" <> id, _params, socket) do
    # Sessions are created via the REST API; a channel only attaches to an
    # existing one. Rejecting unknown ids stops a stale tab from resurrecting a
    # session that was already closed.
    if Terminal.exists?(id) do
      :ok = Terminal.subscribe(id, self())
      {:ok, assign(socket, :session_id, id)}
    else
      {:error, %{reason: "unknown_session"}}
    end
  end

  # Keystrokes arrive as raw binary frames.
  @impl true
  def handle_in("input", {:binary, data}, socket) do
    Terminal.send_input(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Terminal.resize(socket.assigns.session_id, cols, rows)
    {:noreply, socket}
  end

  # PTY output → push as binary to the browser.
  @impl true
  def handle_info({:pty_output, data}, socket) do
    push(socket, "output", {:binary, data})
    {:noreply, socket}
  end
end
