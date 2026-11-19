defmodule Loom.Terminal.RemoteSessionTest do
  use ExUnit.Case, async: true

  alias Loom.Terminal

  # A stand-in for the device's NodeChannel: hands the test every request the
  # session sends it, and can be made to vanish as a dropped device would.
  defp channel do
    test = self()

    spawn(fn ->
      relay = fn relay ->
        receive do
          :drop ->
            exit(:shutdown)

          msg ->
            send(test, {:channel, msg})
            relay.(relay)
        end
      end

      relay.(relay)
    end)
  end

  defp start(opts \\ []) do
    id = "remote-#{System.unique_integer([:positive])}"
    ch = channel()

    {:ok, pid} =
      Terminal.start_session(id, [node: "mac", channel: ch, cols: 90, rows: 30] ++ opts)

    on_exit(fn -> Terminal.stop_session(id) end)
    %{id: id, ch: ch, pid: pid}
  end

  defp reply(%{pid: pid, id: id}, event, payload),
    do: send(pid, {:node_reply, id, event, payload})

  defp screen(acc \\ "") do
    receive do
      {:pty_output, data} -> screen(acc <> data)
    after
      100 -> acc
    end
  end

  test "asks the device for a terminal at the session's size" do
    %{id: id, pid: pid} = start()

    assert_receive {:channel, {:node_send, ^pid, ^id, "pty_open", %{"cols" => 90, "rows" => 30}}}
    assert Terminal.info(id).node == "mac"
  end

  test "the device's output reaches clients and is replayed to newcomers" do
    s = start()
    reply(s, "pty_opened", %{})
    :ok = Terminal.subscribe(s.id, self(), nil)
    reply(s, "pty_out", %{"data" => Base.encode64("hello\r\n")})
    assert screen() == "hello\r\n"

    late = self()

    spawn(fn ->
      :ok = Terminal.subscribe(s.id, self(), nil)
      send(late, {:late, screen()})
    end)

    assert_receive {:late, "hello\r\n"}, 1000
  end

  test "keystrokes and the driver's size go to the device" do
    %{id: id, pid: pid} = s = start()
    reply(s, "pty_opened", %{})
    :ok = Terminal.subscribe(id, self(), {120, 40})

    assert_receive {:channel,
                    {:node_send, ^pid, ^id, "pty_resize", %{"cols" => 120, "rows" => 40}}}

    Terminal.send_input(id, self(), "ls\r")
    assert_receive {:channel, {:node_send, ^pid, ^id, "pty_in", %{"data" => data}}}
    assert Base.decode64!(data) == "ls\r"
  end

  test "the shell exiting there ends the session" do
    s = start()
    ref = Process.monitor(s.pid)
    reply(s, "pty_exit", %{"code" => 0})
    assert_receive {:DOWN, ^ref, :process, _, :normal}
  end

  test "closing it hangs up on the device" do
    %{id: id} = start()
    assert_receive {:channel, {:node_send, _, ^id, "pty_open", _}}
    Terminal.stop_session(id)
    assert_receive {:channel, {:node_cancel, ^id}}
  end

  test "a dropped device is said on screen, and the session waits to be closed" do
    s = start()
    reply(s, "pty_opened", %{})
    :ok = Terminal.subscribe(s.id, self(), nil)
    send(s.ch, :drop)

    assert screen() =~ "mac disconnected"
    Terminal.send_input(s.id, self(), "ls\r")
    refute_receive {:channel, {:node_send, _, _, "pty_in", _}}
    assert Process.alive?(s.pid)
  end

  test "a device that cannot open one says why" do
    s = start()
    :ok = Terminal.subscribe(s.id, self(), nil)
    reply(s, "error", %{"message" => "no such shell"})
    assert screen() =~ "mac could not open a terminal: no such shell"
  end

  test "a device that never answers is called out, not waited on forever" do
    s = start()
    :ok = Terminal.subscribe(s.id, self(), nil)
    Process.sleep(400)
    assert screen() =~ "did not open a terminal"
  end
end
