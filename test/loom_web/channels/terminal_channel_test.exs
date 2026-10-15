defmodule LoomWeb.TerminalChannelTest do
  use LoomWeb.ChannelCase, async: false

  alias LoomWeb.UserSocket

  # The suite ends with `System.halt`, which does not stop the application, so
  # a terminal left running keeps its shell alive — and the node waits on it
  # forever. Stop every terminal a test opened.
  setup do
    on_exit(fn ->
      for %{id: id} <- Loom.Terminal.list_sessions(), do: Loom.Terminal.stop_session(id)
    end)
  end

  defp join_terminal(id) do
    {:ok, _pid} = Loom.Terminal.start_session(id, cols: 80, rows: 24)

    {:ok, _reply, socket} =
      socket(UserSocket, nil, %{})
      |> subscribe_and_join(LoomWeb.TerminalChannel, "terminal:#{id}", %{
        "cols" => 80,
        "rows" => 24
      })

    socket
  end

  defp push_input(socket, str), do: push(socket, "input", {:binary, str})

  # Collect binary "output" pushes until we see `needle` or time out.
  defp await_output(needle, acc \\ "", timeout \\ 4000) do
    receive do
      %Phoenix.Socket.Message{event: "output", payload: {:binary, data}} ->
        acc = acc <> data
        if String.contains?(acc, needle), do: {:ok, acc}, else: await_output(needle, acc, timeout)
    after
      timeout -> {:timeout, acc}
    end
  end

  test "shell output flows back with color-capable tty attached" do
    socket = join_terminal("test-#{System.unique_integer([:positive])}")
    push_input(socket, "echo TERMCHECK=$TERM COLORS=$(tput colors)\n")

    # Wait for the command *result*, not the echoed keystrokes: the typed line
    # contains "COLORS=$(tput colors)", while the executed output is "COLORS=256".
    assert {:ok, out} = await_output("COLORS=256")
    assert out =~ "xterm-256color"
    assert out =~ "COLORS=256"
  end

  test "input reaches the shell and its output comes back" do
    socket = join_terminal("test-#{System.unique_integer([:positive])}")
    push_input(socket, "echo hello-from-loom\n")

    assert {:ok, out} = await_output("hello-from-loom")
    assert out =~ "hello-from-loom"
  end

  test "reattaching replays prior output so a reconnecting client sees the screen" do
    id = "test-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Loom.Terminal.start_session(id, cols: 80, rows: 24)

    # First client produces some output, then leaves.
    {:ok, _r, s1} =
      socket(UserSocket, nil, %{})
      |> subscribe_and_join(LoomWeb.TerminalChannel, "terminal:#{id}", %{})

    push(s1, "input", {:binary, "echo replay-marker-123\n"})
    assert {:ok, _} = await_output("replay-marker-123")
    Process.unlink(s1.channel_pid)
    :ok = close(s1)

    # A fresh client attaching to the same session gets the buffer replayed.
    {:ok, _r2, _s2} =
      socket(UserSocket, nil, %{})
      |> subscribe_and_join(LoomWeb.TerminalChannel, "terminal:#{id}", %{})

    assert {:ok, out} = await_output("replay-marker-123")
    assert out =~ "replay-marker-123"
  end

  test "joining an unknown session is rejected" do
    assert {:error, %{reason: "unknown_session"}} =
             socket(UserSocket, nil, %{})
             |> subscribe_and_join(LoomWeb.TerminalChannel, "terminal:does-not-exist", %{})
  end

  test "resize changes the pty geometry (SIGWINCH)" do
    socket = join_terminal("test-#{System.unique_integer([:positive])}")
    push(socket, "resize", %{"cols" => 120, "rows" => 40})
    Process.sleep(200)
    push_input(socket, "echo SIZE=$(tput cols)x$(tput lines)\n")

    assert {:ok, out} = await_output("SIZE=120x40")
    assert out =~ "SIZE=120x40"
  end

  test "join applies the client size so the shell sees correct columns immediately" do
    # Session created at the default 80 cols...
    id = "test-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Loom.Terminal.start_session(id, cols: 80, rows: 24)

    # ...but the client joins reporting a wider terminal. The shell should see
    # the wide size right away, without a separate resize event. This is the
    # fix for TUIs (Claude Code) laying out their first screen at the wrong width.
    {:ok, _reply, socket} =
      socket(UserSocket, nil, %{})
      |> subscribe_and_join(LoomWeb.TerminalChannel, "terminal:#{id}", %{
        "cols" => 150,
        "rows" => 45
      })

    push_input(socket, "echo SIZE=$(tput cols)x$(tput lines)\n")
    assert {:ok, out} = await_output("SIZE=150x45")
    assert out =~ "SIZE=150x45"
  end
end
