defmodule LoomWeb.NodeChannel do
  @moduledoc """
  One connected device. Relays requests from `LoomWeb.NodeController` down to
  the device and the device's answers back up, matched by an `id` the
  requester picks.

  Requester → channel (Erlang messages):
    - `{:node_send, pid, id, event, payload}` — push `event` to the device with
      `id` added. The first send for an `id` registers `pid` as the one its
      answers go to, and monitors it: if the requester goes away (the CLI was
      interrupted), the device is told to `cancel`.
    - `{:node_cancel, id}` — the same, for a requester that is still alive.

  Device → channel → requester, as `{:node_reply, id, event, payload}`:
    - "out"     : `{id, stream, data}`, output from a running command
    - "exit"    : `{id, code, timed_out, truncated}`, the command is done
    - "chunk"   : `{id, data}`, part of a file being read
    - "done"    : `{id, size}`, the whole file has been sent
    - "written" : `{id, size}`, a file write landed
    - "error"   : `{id, message}`, the request failed on the device

  "exit", "done", "written" and "error" end a request. The requester monitors
  this process, so a dropped device shows up there as a `:DOWN` — and the
  device kills whatever it was running when it loses the connection, so
  nothing is left behind on either side.
  """
  use Phoenix.Channel

  require Logger

  @final ~w(exit done written error)

  @impl true
  def join("node", info, socket) do
    case Loom.Nodes.connected(socket.assigns.node_id, self(), info) do
      {:ok, node} -> {:ok, %{name: node.name}, assign(socket, :requests, %{})}
      {:error, _} -> {:error, %{reason: "unknown device"}}
    end
  end

  @impl true
  def handle_in(event, %{"id" => id} = payload, socket)
      when event in ~w(out exit chunk done written error) do
    case socket.assigns.requests do
      %{^id => {pid, ref}} ->
        send(pid, {:node_reply, id, event, Map.delete(payload, "id")})

        if event in @final do
          Process.demonitor(ref, [:flush])
          {:noreply, update(socket, &Map.delete(&1, id))}
        else
          {:noreply, socket}
        end

      # Late output for a request already cancelled.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_in(event, _payload, socket) do
    Logger.warning("NodeChannel: unexpected #{inspect(event)} from the device")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_send, pid, id, event, payload}, socket) do
    socket =
      if Map.has_key?(socket.assigns.requests, id) do
        socket
      else
        update(socket, &Map.put(&1, id, {pid, Process.monitor(pid)}))
      end

    push(socket, event, Map.put(payload, "id", id))
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case Enum.find(socket.assigns.requests, fn {_id, {_pid, r}} -> r == ref end) do
      {id, _} ->
        push(socket, "cancel", %{"id" => id})
        {:noreply, update(socket, &Map.delete(&1, id))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:node_cancel, id}, socket) do
    case socket.assigns.requests do
      %{^id => {_pid, ref}} ->
        Process.demonitor(ref, [:flush])
        push(socket, "cancel", %{"id" => id})
        {:noreply, update(socket, &Map.delete(&1, id))}

      _ ->
        {:noreply, socket}
    end
  end

  # A newer connection from the same device, or its token was revoked.
  def handle_info(:node_replaced, socket), do: {:stop, {:shutdown, :replaced}, socket}

  defp update(socket, fun), do: assign(socket, :requests, fun.(socket.assigns.requests))
end
