defmodule Loom.Turn do
  @moduledoc """
  The servers a Connect line is found through (node/rtc.go, Desktop.tsx):
  STUN, for each side to learn the address the internet sees it at, and TURN,
  a relay both sides go through when no direct path is found. TURN is
  optional; without it a line that can't be punched goes round by Loom
  (`LoomWeb.DevicePortSocket`), over TCP.

  Both sides get TURN, not one: a relay lets through only the addresses its
  client has asked it to, and a far side behind a NAT that maps each
  destination to its own port never shows the relay the port it said it
  would. Relayed both ways, each side asks for the other's relayed address,
  which is the one packets come from.

  One provider for now, chosen by configuration (`config :loom, Loom.Turn`):

    * `kvs_channel` — Amazon Kinesis Video Streams' TURN, through a signaling
      channel of its own (its ARN): short-lived credentials, minted per
      connect. See `Loom.Turn.KVS` for the AWS credentials it takes.

  Credentials are kept for less than they last, so connects close together
  share them; a line keeps its allocation past their expiry.
  """
  use GenServer
  require Logger

  # Reachable from mainland China as well as outside it; a server that
  # doesn't answer only costs its share of the wait.
  @stun [
    "stun:stun.miwifi.com:3478",
    "stun:stun.chat.bilibili.com:3478",
    "stun:stun.cloudflare.com:3478"
  ]

  # KVS's credentials last five minutes; a line needs them only to start.
  @keep_ms :timer.minutes(4)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "STUN URLs."
  def stun, do: @stun

  @doc """
  TURN servers, as RTCIceServer (`%{"urls" => [...], "username" => ...,
  "credential" => ...}`); `[]` when none is configured, or when the provider
  could not be reached (logged), so a connect goes on without.
  """
  def ice_servers do
    GenServer.call(__MODULE__, :ice_servers, 15_000)
  catch
    :exit, reason ->
      Logger.warning("turn: #{inspect(reason)}")
      []
  end

  @impl true
  def init(_opts), do: {:ok, %{servers: [], until: 0, provider: nil}}

  @impl true
  def handle_call(:ice_servers, _from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      provider() == nil ->
        {:reply, [], state}

      state.servers != [] and now < state.until ->
        {:reply, state.servers, state}

      true ->
        {kind, config} = provider()

        case fetch(kind, config, state.provider) do
          {:ok, servers, cache} ->
            {:reply, servers, %{state | servers: servers, until: now + @keep_ms, provider: cache}}

          {:error, reason} ->
            Logger.warning("turn: #{kind}: #{inspect(reason)}")
            {:reply, [], %{state | servers: [], provider: nil}}
        end
    end
  end

  defp provider do
    config = Application.get_env(:loom, __MODULE__, [])

    case config[:kvs_channel] do
      arn when is_binary(arn) and arn != "" -> {:kvs, config}
      _ -> nil
    end
  end

  defp fetch(:kvs, config, cache), do: Loom.Turn.KVS.ice_servers(config, cache)
end
