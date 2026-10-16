defmodule Loom.Terminal.SessionTest do
  use ExUnit.Case, async: false

  alias Loom.Terminal

  # See terminal_channel_test.exs: a shell left running keeps the node alive.
  setup do
    on_exit(fn ->
      for %{id: id} <- Terminal.list_sessions(), do: Terminal.stop_session(id)
    end)

    id = "test-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Terminal.start_session(id, cols: 80, rows: 24)
    %{id: id}
  end

  # A stand-in for one browser: forwards what the session sends it, tagged, so
  # the test can tell two clients' screens apart.
  defp client(id, size) do
    test = self()
    tag = make_ref()

    pid =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        forward(test, tag)
      end)

    :ok = Terminal.subscribe(id, pid, size)
    send(pid, :go)
    {pid, tag}
  end

  defp forward(test, tag) do
    receive do
      {:pty_output, data} -> send(test, {tag, data})
    end

    forward(test, tag)
  end

  defp await(tag, needle, acc \\ "") do
    receive do
      {^tag, data} ->
        acc = acc <> data
        if String.contains?(acc, needle), do: {:ok, acc}, else: await(tag, needle, acc)
    after
      4000 -> {:timeout, acc}
    end
  end

  defp size_check(id, {pid, _}), do: Terminal.send_input(id, pid, "echo SIZE=$(tput cols)x$(tput lines)\n")

  test "every attached client sees the output, whoever typed", %{id: id} do
    {a, ta} = client(id, {80, 24})
    {_b, tb} = client(id, {80, 24})

    Terminal.send_input(id, a, "echo both-$((40+2))\n")

    assert {:ok, _} = await(ta, "both-42")
    assert {:ok, _} = await(tb, "both-42")
  end

  test "the size follows whoever typed last", %{id: id} do
    a = client(id, {100, 30})
    b = client(id, {60, 20})
    {_, tb} = b

    # The newcomer drives.
    size_check(id, b)
    assert {:ok, _} = await(tb, "SIZE=60x20")

    # The first client typing takes the wheel back, and its size with it.
    size_check(id, a)
    assert {:ok, _} = await(tb, "SIZE=100x30")
  end

  test "a resize from a client that is only watching changes nothing", %{id: id} do
    a = client(id, {100, 30})
    {b, tb} = client(id, {60, 20})

    Terminal.resize(id, elem(a, 0), 120, 40)
    Terminal.resize(id, b, 70, 25)
    size_check(id, {b, tb})
    assert {:ok, _} = await(tb, "SIZE=70x25")
  end

  test "a terminal's reply from a client that is not driving is dropped", %{id: id} do
    {a, ta} = client(id, {80, 24})
    {b, _tb} = client(id, {80, 24})

    # `cat -v` makes anything that reaches the shell visible. b drives; a's
    # xterm answering a cursor-position query must not reach it — and must not
    # make a the driver either.
    Terminal.send_input(id, b, "cat -v\n")
    Process.sleep(200)
    Terminal.send_input(id, a, "\e[12;1R\e[?1;2c")
    Terminal.send_input(id, b, "\e[3;4Rfrom-b\n")

    assert {:ok, out} = await(ta, "from-b")
    assert out =~ "^[[3;4R"
    refute out =~ "12;1R"
    refute out =~ "?1;2c"
  end

  test "when the driver leaves, a remaining client takes over its size", %{id: id} do
    {a, ta} = client(id, {100, 30})
    {b, _} = client(id, {60, 20})

    ref = Process.monitor(b)
    Process.exit(b, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    size_check(id, {a, ta})
    assert {:ok, _} = await(ta, "SIZE=100x30")
  end
end
