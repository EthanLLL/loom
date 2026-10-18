defmodule Loom.Nodes do
  @moduledoc """
  The user's own machines — a Mac, a WSL box — that agents can run commands on.

  Each one runs `loom-node daemon` (the Go program in `node/`), which dials
  loom over the same Cloudflare tunnel the browser uses and joins
  `LoomWeb.NodeChannel`. An agent reaches it through the `loom-node` CLI on this
  host, which talks to `LoomWeb.NodeController`; the controller finds the
  device's channel here and relays. See docs/architecture.md §4.4.

  One process owns the registry. `~/.loom/nodes.json` is the truth for what is
  registered; who is online is only in memory, from the channels that have
  checked in.

  ## Credentials

  - A device authenticates with a token, stored here only as a SHA-256 hash.
  - The token is minted when its install script is fetched: registering a device
    (or asking again) yields a one-time install code, good for
    `@install_ttl`, and redeeming it rotates the token. So reinstalling is how a
    lost token is replaced, and the old one stops working that moment.
  - The CLI authenticates with a key in `~/.loom/node-cli.json`, readable only
    by this user — the same reach a unix socket would have had, on the port
    loom already listens on. See `LoomWeb.Plugs.NodeCliAuth`.

  ## Broadcasts

  On the lobby topic (`Loom.Agent.lobby_topic/0`), for the sidebar:
  `{:node_summary, summary}` and `{:node_removed, id}`. On `"nodes"`,
  `{:node_online, id}`, for a request waiting on a device that is reconnecting.
  """
  use GenServer

  require Logger

  @name __MODULE__
  @persisted ~w(id name token_hash created_at os arch hostname version last_seen_at)a
  @install_ttl :timer.hours(1)
  @name_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Every device, oldest first, with `online`."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc "Register a device. `{:ok, summary, install_code}` or `{:error, reason}`."
  def create(name, server \\ @name), do: GenServer.call(server, {:create, name})

  @doc "Rename a device. Its token, and so the device itself, is unaffected."
  def rename(id, name, server \\ @name), do: GenServer.call(server, {:rename, id, name})

  @doc "Forget a device: its token stops working and a live connection is dropped."
  def delete(id, server \\ @name), do: GenServer.call(server, {:delete, id})

  @doc "A fresh one-time install code for a registered device."
  def install_code(id, server \\ @name), do: GenServer.call(server, {:install_code, id})

  @doc """
  Trade an install code for the device's new token: `{:ok, summary, token}`.
  The previous token, if any, is dead from here on.
  """
  def redeem(code, server \\ @name), do: GenServer.call(server, {:redeem, code})

  @doc "The device a token belongs to: `{:ok, id}` or `:error`."
  def authenticate(token, server \\ @name), do: GenServer.call(server, {:authenticate, token})

  @doc """
  Called by a device's channel once it has joined, with what the device says
  about itself. A previous connection for the same device is told to stop —
  the newer one is the one the device is actually on.
  """
  def connected(id, pid, info, server \\ @name),
    do: GenServer.call(server, {:connected, id, pid, info})

  @doc """
  The channel for a device, by name: `{:ok, pid}`, `{:offline, summary}` or
  `:unknown`.
  """
  def lookup(name, server \\ @name), do: GenServer.call(server, {:lookup, name})

  @doc """
  Like `lookup/2`, but an offline device gets `timeout` ms to come back — a Mac
  just woken from sleep is usually seconds from reconnecting.
  """
  def await(name, timeout, server \\ @name) do
    Phoenix.PubSub.subscribe(Loom.PubSub, "nodes")

    try do
      wait(name, server, System.monotonic_time(:millisecond) + timeout)
    after
      Phoenix.PubSub.unsubscribe(Loom.PubSub, "nodes")
    end
  end

  defp wait(name, server, deadline) do
    case lookup(name, server) do
      {:offline, _summary} = offline ->
        remaining = deadline - System.monotonic_time(:millisecond)

        receive do
          {:node_online, _id} -> wait(name, server, deadline)
        after
          max(remaining, 0) -> offline
        end

      other ->
        other
    end
  end

  @doc "Where the registry is kept."
  def path, do: Path.join(dir(), "nodes.json")

  @doc "The file the CLI reads to find, and prove itself to, this node."
  def cli_path, do: Path.join(dir(), "node-cli.json")

  @doc "The key the CLI has to present."
  def cli_key do
    case :persistent_term.get({__MODULE__, :cli_key}, nil) do
      nil -> raise "Loom.Nodes is not running"
      key -> key
    end
  end

  defp dir, do: Application.get_env(:loom, __MODULE__, [])[:dir] || Loom.Agent.Store.home()

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    cli_path = Keyword.get(opts, :cli_path, cli_path())
    :persistent_term.put({__MODULE__, :cli_key}, write_cli_file(cli_path))

    nodes = path |> load() |> Map.new(&{&1.id, &1})
    {:ok, %{path: path, nodes: nodes, online: %{}, codes: %{}}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
      |> Enum.map(&summary(&1, state))

    {:reply, nodes, state}
  end

  def handle_call({:create, name}, _from, state) do
    with {:ok, name} <- check_name(name, nil, state) do
      node = %{
        id: "n_" <> random(6),
        name: name,
        token_hash: nil,
        created_at: now(),
        os: nil,
        arch: nil,
        hostname: nil,
        version: nil,
        last_seen_at: nil
      }

      state = save(put_in(state.nodes[node.id], node))
      {code, state} = new_code(node.id, state)
      announce(node, state)
      {:reply, {:ok, summary(node, state), code}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:rename, id, name}, _from, state) do
    with {:ok, node} <- fetch(id, state),
         {:ok, name} <- check_name(name, id, state) do
      node = %{node | name: name}
      state = save(put_in(state.nodes[id], node))
      announce(node, state)
      {:reply, {:ok, summary(node, state)}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case fetch(id, state) do
      {:ok, _node} ->
        state = drop_connection(id, state)
        codes = for {_code, {owner, _}} = entry <- state.codes, owner != id, into: %{}, do: entry
        state = save(%{state | nodes: Map.delete(state.nodes, id), codes: codes})
        Phoenix.PubSub.broadcast(Loom.PubSub, Loom.Agent.lobby_topic(), {:node_removed, id})
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:install_code, id}, _from, state) do
    case fetch(id, state) do
      {:ok, _node} ->
        {code, state} = new_code(id, state)
        {:reply, {:ok, code}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:redeem, code}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    with {id, expires} when expires > now_ms <- Map.get(state.codes, code),
         {:ok, node} <- fetch(id, state) do
      token = "ln_" <> random(32)
      node = %{node | token_hash: hash(token)}
      state = %{state | codes: Map.delete(state.codes, code)}
      # The old token is dead; so is a connection made with it.
      state = id |> drop_connection(state) |> then(&save(put_in(&1.nodes[id], node)))
      {:reply, {:ok, summary(node, state), token}, state}
    else
      _ -> {:reply, {:error, :invalid_code}, %{state | codes: Map.delete(state.codes, code)}}
    end
  end

  def handle_call({:authenticate, token}, _from, state) when is_binary(token) do
    hashed = hash(token)

    found =
      Enum.find(state.nodes, fn {_id, node} ->
        node.token_hash != nil and Plug.Crypto.secure_compare(node.token_hash, hashed)
      end)

    case found do
      {id, _node} -> {:reply, {:ok, id}, state}
      nil -> {:reply, :error, state}
    end
  end

  def handle_call({:authenticate, _token}, _from, state), do: {:reply, :error, state}

  def handle_call({:connected, id, pid, info}, _from, state) do
    case fetch(id, state) do
      {:ok, node} ->
        state = drop_connection(id, state)
        ref = Process.monitor(pid)

        node =
          Map.merge(node, %{
            os: info["os"],
            arch: info["arch"],
            hostname: info["hostname"],
            version: info["version"],
            last_seen_at: now()
          })

        state = %{state | online: Map.put(state.online, id, {pid, ref})}
        state = save(put_in(state.nodes[id], node))
        announce(node, state)
        Phoenix.PubSub.broadcast(Loom.PubSub, "nodes", {:node_online, id})
        {:reply, {:ok, summary(node, state)}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:lookup, name}, _from, state) do
    reply =
      case Enum.find(Map.values(state.nodes), &same_name?(&1.name, name)) do
        nil ->
          :unknown

        node ->
          case Map.fetch(state.online, node.id) do
            {:ok, {pid, _ref}} -> {:ok, pid}
            :error -> {:offline, summary(node, state)}
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.online, fn {_id, {_pid, r}} -> r == ref end) do
      {id, _} ->
        state = %{state | online: Map.delete(state.online, id)}

        state =
          case state.nodes do
            %{^id => node} ->
              node = %{node | last_seen_at: now()}
              state = save(put_in(state.nodes[id], node))
              announce(node, state)
              state

            _ ->
              state
          end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp summary(node, state) do
    node
    |> Map.drop([:token_hash])
    |> Map.put(:online, Map.has_key?(state.online, node.id))
  end

  defp announce(node, state) do
    Phoenix.PubSub.broadcast(
      Loom.PubSub,
      Loom.Agent.lobby_topic(),
      {:node_summary, summary(node, state)}
    )
  end

  # Stops the device's channel. The device takes a channel that goes away as a
  # dropped connection and redials, and a dead token is refused at connect.
  defp drop_connection(id, state) do
    case Map.pop(state.online, id) do
      {{pid, ref}, online} ->
        Process.demonitor(ref, [:flush])
        send(pid, :node_replaced)
        %{state | online: online}

      {nil, _} ->
        state
    end
  end

  defp fetch(id, state) do
    case state.nodes do
      %{^id => node} -> {:ok, node}
      _ -> {:error, :not_found}
    end
  end

  defp check_name(name, self_id, state) when is_binary(name) do
    name = String.trim(name)

    cond do
      not Regex.match?(@name_format, name) ->
        {:error, "a name is 1–32 letters, digits, dots, dashes or underscores"}

      Enum.any?(state.nodes, fn {id, node} -> id != self_id and same_name?(node.name, name) end) ->
        {:error, "there is already a device called #{name}"}

      true ->
        {:ok, name}
    end
  end

  defp check_name(_name, _self_id, _state), do: {:error, "a name is required"}

  defp same_name?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_name?(_a, _b), do: false

  defp new_code(id, state) do
    code = random(16)
    expires = System.monotonic_time(:millisecond) + @install_ttl
    now_ms = System.monotonic_time(:millisecond)
    # Expired codes go whenever a new one is made; there are only ever a few.
    codes = for {c, {_, e} = v} <- state.codes, e > now_ms, into: %{}, do: {c, v}
    {code, %{state | codes: Map.put(codes, code, {id, expires})}}
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The key is kept across restarts, so a CLI call that straddles a deploy
  # still gets through; the URL is rewritten in case the port changed.
  defp write_cli_file(path) do
    key =
      with {:ok, body} <- File.read(path),
           {:ok, %{"key" => key}} when is_binary(key) <- Jason.decode(body) do
        key
      else
        _ -> random(32)
      end

    http = Application.get_env(:loom, LoomWeb.Endpoint, [])[:http] || []
    ip = http |> Keyword.get(:ip, {127, 0, 0, 1}) |> loopback()
    port = Keyword.get(http, :port, 4000)
    body = Jason.encode!(%{url: "http://#{ip}:#{port}", key: key}, pretty: true)

    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, body)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    key
  end

  # Listening on every interface still answers on loopback, which is the one
  # address the CLI is sure to reach.
  defp loopback({0, 0, 0, 0}), do: "127.0.0.1"
  defp loopback({0, 0, 0, 0, 0, 0, 0, 0}), do: "[::1]"
  defp loopback({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp loopback(ip), do: "[#{ip |> :inet.ntoa() |> to_string()}]"

  defp load(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"nodes" => nodes}} when is_list(nodes) ->
            for node <- nodes do
              Map.new(@persisted, fn key -> {key, node[Atom.to_string(key)]} end)
            end

          _ ->
            aside = "#{path}.bad-#{System.os_time(:second)}"
            File.rename(path, aside)
            Logger.error("Loom.Nodes cannot read #{path}; moved it to #{aside}")
            []
        end

      {:error, :enoent} ->
        []
    end
  end

  defp save(state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
      |> Enum.map(&Map.take(&1, @persisted))

    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(%{nodes: nodes}, pretty: true))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, state.path)
    state
  end
end
