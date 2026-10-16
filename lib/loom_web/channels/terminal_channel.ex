defmodule LoomWeb.TerminalChannel do
  @moduledoc """
  One channel == one client of one terminal session. The topic is
  `terminal:<id>`; several browsers may join the same one at once, see
  `Loom.Terminal.Session`.

  Client → server:
    - binary frames  : raw keystrokes → PTY stdin
    - "resize" event : %{"cols" => c, "rows" => r}

  Server → client:
    - binary frames  : raw PTY output → xterm.js
  """
  use Phoenix.Channel

  alias Loom.Terminal

  @impl true
  def join("terminal:" <> id, params, socket) do
    # Sessions are created via the REST API; a channel only attaches to an
    # existing one. Rejecting unknown ids stops a stale tab from resurrecting a
    # session that was already closed.
    if Terminal.exists?(id) do
      # Attach with the client's real terminal size, so the PTY fits it before
      # the shell produces any output the client cares about. The session was
      # created at a default size; without this, a TUI (e.g. Claude Code) would
      # lay out its first screen at the wrong column count and wrap/table
      # rendering would be broken until the process is restarted.
      size =
        case params do
          %{"cols" => cols, "rows" => rows} when is_integer(cols) and is_integer(rows) ->
            {cols, rows}

          _ ->
            nil
        end

      :ok = Terminal.subscribe(id, self(), size)
      {:ok, assign(socket, :session_id, id)}
    else
      {:error, %{reason: "unknown_session"}}
    end
  end

  # Keystrokes arrive as raw binary frames.
  @impl true
  def handle_in("input", {:binary, data}, socket) do
    Terminal.send_input(socket.assigns.session_id, self(), data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Terminal.resize(socket.assigns.session_id, self(), cols, rows)
    {:noreply, socket}
  end

  # PTY output → push as binary to the browser.
  @impl true
  def handle_info({:pty_output, data}, socket) do
    push(socket, "output", {:binary, data})
    {:noreply, socket}
  end
end
