defmodule LoomWeb.DevicesController do
  @moduledoc """
  The Devices dialog's API: register, rename and remove the machines in
  `Loom.Nodes`. The list itself, and who is online, arrive over the lobby
  channel; these answer only so the dialog can show the result at once.

  Registering a device, or asking to reinstall one, returns an install `code`.
  The dialog turns it into `curl -fsSL <origin>/node/install/<code> | sh`; see
  `LoomWeb.NodeInstallController`.

  Connect, the device's own screen, is `ice/2` for the servers a line is
  found through, `rtc/2` for a line from the browser to a port on the device
  (direct, or through a TURN relay), and `port/2` for the relay through Loom
  when there is none.
  """
  use LoomWeb, :controller

  alias Loom.Nodes

  # Gathering takes the device up to 5 s, and a device just woken may be slow.
  @rtc_timeout 15_000

  def index(conn, _params), do: json(conn, %{nodes: Nodes.list()})

  @doc """
  `{stun, turn}`: STUN URLs, and TURN servers as RTCIceServer (none when no
  relay is configured), for the browser's side of `rtc/2`. See `Loom.Turn`.
  """
  def ice(conn, _params), do: json(conn, %{stun: Loom.Turn.stun(), turn: Loom.Turn.ice_servers()})

  def create(conn, params) do
    case Nodes.create(params["name"]) do
      {:ok, node, code} -> conn |> put_status(201) |> json(%{node: node, code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Nodes.rename(id, params["name"]) do
      {:ok, node} -> json(conn, %{node: node})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Nodes.delete(id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def install(conn, %{"id" => id}) do
    case Nodes.install_code(id) do
      {:ok, code} -> json(conn, %{code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc """
  Hands the browser's WebRTC offer, for a `port` on the device's loopback, to
  the device and answers with the device's: `{sdp}`. The two then find a way
  to each other, or don't, without loom (see node/rtc.go). The device is
  given the same servers as `ice/2` gives the browser. 409 when the device is offline, 502 when it
  refused, 504 when it didn't answer (a loom-node from before this).
  """
  def rtc(conn, %{"id" => id, "sdp" => sdp, "port" => port})
      when is_binary(sdp) and is_integer(port) do
    case Nodes.lookup_id(id) do
      {:ok, channel} ->
        req = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        ref = Process.monitor(channel)

        send(
          channel,
          {:node_send, self(), req, "rtc_offer",
           %{
             "sdp" => sdp,
             "ice_servers" => Loom.Turn.stun(),
             "turn_servers" => Loom.Turn.ice_servers(),
             "port" => port
           }}
        )

        receive do
          {:node_reply, ^req, "rtc_answer", %{"sdp" => answer}} ->
            Process.demonitor(ref, [:flush])
            json(conn, %{sdp: answer})

          {:node_reply, ^req, "error", payload} ->
            Process.demonitor(ref, [:flush])
            conn |> put_status(502) |> json(%{error: payload["message"]})

          {:DOWN, ^ref, :process, _pid, _reason} ->
            conn |> put_status(409) |> json(%{error: "the device went offline"})
        after
          @rtc_timeout ->
            send(channel, {:node_cancel, req})
            Process.demonitor(ref, [:flush])
            conn |> put_status(504) |> json(%{error: "the device did not answer"})
        end

      {:offline, _} ->
        conn |> put_status(409) |> json(%{error: "the device is offline"})

      :unknown ->
        refuse(conn, :not_found)
    end
  end

  def rtc(conn, _params),
    do: conn |> put_status(400) |> json(%{error: "sdp and port are required"})

  @doc """
  Upgrades to `LoomWeb.DevicePortSocket`, for `port` on the device's
  loopback. A WebSocket can't carry the header `RequireAuth` reads, so the
  login token comes as `?token=`, as it does for `LoomWeb.BrowserController`.
  """
  def port(conn, %{"id" => id, "port" => port} = params) do
    with {:ok, _login} <- Loom.Auth.verify_token(params["token"]),
         {port, ""} when port in 1..65_535 <- Integer.parse(port),
         {:ok, channel} <- Nodes.lookup_id(id) do
      conn
      |> WebSockAdapter.upgrade(LoomWeb.DevicePortSocket, {channel, port},
        timeout: :timer.hours(4),
        compress: true
      )
      |> halt()
    else
      {:error, _} -> send_resp(conn, 401, "")
      {:offline, _} -> send_resp(conn, 409, "")
      :unknown -> send_resp(conn, 404, "")
      # Not a port number.
      _ -> send_resp(conn, 400, "")
    end
  end

  defp refuse(conn, :not_found), do: conn |> put_status(404) |> json(%{error: "no such device"})
  defp refuse(conn, reason), do: conn |> put_status(422) |> json(%{error: reason})
end
