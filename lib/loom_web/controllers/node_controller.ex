defmodule LoomWeb.NodeController do
  @moduledoc """
  The `loom-node` CLI's side of a device: list, exec, read, write. Behind
  `LoomWeb.Plugs.NodeCliAuth`, so only this host reaches it.

  Answers that stream — exec and read — are NDJSON, one event per line, as the
  device sent them plus `"t"` for the event name (see `LoomWeb.NodeChannel`),
  and `{"t":"ping"}` every second of silence. The ping is how an interrupted
  CLI is noticed: a chunk that cannot be written means it is gone, and the
  device is told to cancel. A device lost mid-request ends the stream with
  `{"t":"error","lost":true}`.

  A device that is offline gets `@await_ms` to come back before the request is
  refused with 503; one that does not exist is a 404. Both carry
  `{"error": message}`, written for the model reading the CLI's stderr.
  """
  use LoomWeb, :controller

  alias Loom.Nodes

  # Overridable so tests need not sit through it.
  @await_ms Application.compile_env(:loom, [__MODULE__, :await_ms], 10_000)
  @default_timeout 120
  @max_timeout 1_800
  # Beyond the device's own deadline (`timeout` plus its kill grace), how long
  # to wait for the device to say so before giving up on it.
  @slack_ms 30_000
  @chunk 256 * 1024
  @max_write 100 * 1024 * 1024

  def list(conn, _params), do: json(conn, %{nodes: Nodes.list()})

  def exec(conn, %{"node" => name, "cmd" => cmd} = params) when is_binary(cmd) do
    timeout = params |> Map.get("timeout", @default_timeout) |> clamp_timeout()

    payload = %{
      "cmd" => cmd,
      "cwd" => params["cwd"],
      "timeout" => timeout,
      "session" => params["session"]
    }

    with_node(conn, name, fn pid ->
      stream(conn, pid, "exec", payload, timeout * 1000 + @slack_ms)
    end)
  end

  def exec(conn, _params), do: bad_request(conn, "node and cmd are required")

  def read(conn, %{"node" => name, "path" => path}) do
    with_node(conn, name, fn pid ->
      stream(conn, pid, "read", %{"path" => path}, :timer.minutes(10))
    end)
  end

  def read(conn, _params), do: bad_request(conn, "node and path are required")

  def write(conn, %{"node" => name, "path" => path}) do
    with_node(conn, name, fn pid ->
      id = request_id()
      ref = Process.monitor(pid)
      upload(conn, pid, ref, id, path, 0)
    end)
  end

  def write(conn, _params), do: bad_request(conn, "node and path are required")

  # ── Streaming ───────────────────────────────────────────────────────────

  defp stream(conn, pid, event, payload, limit_ms) do
    id = request_id()
    ref = Process.monitor(pid)
    send(pid, {:node_send, self(), id, event, payload})

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> send_chunked(200)

    relay(conn, pid, ref, id, System.monotonic_time(:millisecond) + limit_ms)
  end

  defp relay(conn, pid, ref, id, deadline) do
    receive do
      {:node_reply, ^id, event, payload} ->
        case line(conn, Map.put(payload, "t", event)) do
          {:ok, conn} when event in ~w(exit done error) ->
            Process.demonitor(ref, [:flush])
            conn

          {:ok, conn} ->
            relay(conn, pid, ref, id, deadline)

          {:error, _closed} ->
            cancel(pid, ref, id)
            conn
        end

      {:DOWN, ^ref, :process, _pid, _reason} ->
        lost(conn)
    after
      1_000 ->
        if System.monotonic_time(:millisecond) > deadline do
          cancel(pid, ref, id)
          finish(conn, %{"t" => "error", "message" => "the device stopped answering"})
        else
          case line(conn, %{"t" => "ping"}) do
            {:ok, conn} ->
              relay(conn, pid, ref, id, deadline)

            {:error, _closed} ->
              cancel(pid, ref, id)
              conn
          end
        end
    end
  end

  defp upload(conn, pid, ref, id, path, sent) do
    {result, data, conn} =
      case read_body(conn, length: @chunk, read_length: @chunk) do
        {:more, data, conn} -> {:more, data, conn}
        {:ok, data, conn} -> {:ok, data, conn}
        {:error, reason} -> {:error, reason, conn}
      end

    cond do
      result == :error ->
        cancel(pid, ref, id)
        conn

      sent + byte_size(data) > @max_write ->
        cancel(pid, ref, id)
        conn |> put_status(413) |> json(%{error: "a write is capped at 100 MB"})

      true ->
        final = result == :ok

        send(
          pid,
          {:node_send, self(), id, "write",
           %{"path" => path, "data" => Base.encode64(data), "final" => final}}
        )

        sent = sent + byte_size(data)

        # The device may already have refused (a directory, no permission);
        # no point sending it the rest.
        receive do
          {:node_reply, ^id, "error", payload} ->
            Process.demonitor(ref, [:flush])
            conn |> put_status(422) |> json(%{error: payload["message"]})

          {:DOWN, ^ref, :process, _pid, _reason} ->
            conn |> put_status(503) |> json(%{error: lost_message(), lost: true})
        after
          0 ->
            if final,
              do: await_written(conn, ref, id),
              else: upload(conn, pid, ref, id, path, sent)
        end
    end
  end

  defp await_written(conn, ref, id) do
    receive do
      {:node_reply, ^id, "written", payload} ->
        Process.demonitor(ref, [:flush])
        json(conn, payload)

      {:node_reply, ^id, "error", payload} ->
        Process.demonitor(ref, [:flush])
        conn |> put_status(422) |> json(%{error: payload["message"]})

      {:DOWN, ^ref, :process, _pid, _reason} ->
        conn |> put_status(503) |> json(%{error: lost_message(), lost: true})
    after
      @slack_ms ->
        conn |> put_status(504) |> json(%{error: "the device did not confirm the write"})
    end
  end

  defp lost(conn),
    do: finish(conn, %{"t" => "error", "message" => lost_message(), "lost" => true})

  defp lost_message,
    do: "the device disconnected during the request; anything it was running was killed there"

  defp finish(conn, event) do
    case line(conn, event) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp line(conn, event), do: chunk(conn, [Jason.encode_to_iodata!(event), ?\n])

  # The channel stops forwarding when the requester goes away, but a handler
  # process can outlive one request on a kept-alive connection — so say so.
  defp cancel(pid, ref, id) do
    Process.demonitor(ref, [:flush])
    send(pid, {:node_cancel, id})
  end

  # ── Lookup ──────────────────────────────────────────────────────────────

  defp with_node(conn, name, fun) when is_binary(name) do
    case Nodes.await(name, @await_ms) do
      {:ok, pid} ->
        fun.(pid)

      {:offline, node} ->
        seen = if node.last_seen_at, do: "last seen #{node.last_seen_at}", else: "never connected"

        conn
        |> put_status(503)
        |> json(%{error: "#{node.name} is offline (#{seen})", offline: true})

      :unknown ->
        names = Nodes.list() |> Enum.map_join(", ", & &1.name)
        known = if names == "", do: "no devices are registered", else: "devices: #{names}"
        conn |> put_status(404) |> json(%{error: "no device called #{name}; #{known}"})
    end
  end

  defp with_node(conn, _name, _fun), do: bad_request(conn, "node is required")

  defp bad_request(conn, message), do: conn |> put_status(400) |> json(%{error: message})

  defp clamp_timeout(t) when is_integer(t) and t > 0, do: min(t, @max_timeout)
  defp clamp_timeout(_), do: @default_timeout

  defp request_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
