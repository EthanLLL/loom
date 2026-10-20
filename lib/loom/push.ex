defmodule Loom.Push do
  @moduledoc """
  Notifications on the user's devices when a turn is over, so a long job can
  be left running with the phone locked. Web Push, so the same code reaches an
  iPhone home-screen app (iOS 16.4+), Chrome and Firefox; see
  `Loom.Push.WebPush` for the protocol.

  - **Truth is `~/.loom/push.json`**: the VAPID key pair, made on first boot
    and kept, since every subscription is bound to it, and one subscription
    per device that turned notifications on.
  - **What is sent.** A session broadcasts `{:turn_ended, id, summary}` on
    `Loom.Agent.turns_topic/0` when a turn ends with nothing queued after it
    (not on an interrupt: whoever stopped it knows). Every subscription gets
    the session's title and the start of the last reply, or the error.
  - **Not to a device that is looking.** A device showing a session says so on
    the lobby channel (`watching/3`), and gets nothing for that session while
    it is. Held only in memory, against the channel's pid: a device that drops
    off stops counting as looking.
  - The payload is a Declarative Web Push message (`web_push: 8030`). Safari
    18.4+ shows it on its own if the service worker does not; everything else
    hands it to `frontend/public/sw.js`, which shows the same fields.

  A push service that answers 404 or 410 has dropped the subscription (the
  app was removed, permission withdrawn), and so do we.
  """
  use GenServer

  require Logger

  alias Loom.Push.WebPush

  @name __MODULE__
  @body_limit 180

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def path,
    do:
      Application.get_env(:loom, __MODULE__, [])[:path] ||
        Path.join(Loom.Agent.Store.home(), "push.json")

  @doc "The VAPID public key, base64url, which a browser subscribes with."
  def public_key(server \\ @name), do: GenServer.call(server, :public_key)

  @doc """
  Keep a browser's subscription (`PushSubscription.toJSON()`, string keys) and
  the origin it was made on, which notifications link back to. With `test:
  true` it is sent a notification at once, so turning them on shows they work.
  """
  def subscribe(subscription, origin, opts \\ [], server \\ @name),
    do:
      GenServer.call(server, {:subscribe, subscription, origin, Keyword.get(opts, :test, false)})

  @doc "Forget a subscription, by its endpoint."
  def unsubscribe(endpoint, server \\ @name), do: GenServer.call(server, {:unsubscribe, endpoint})

  @doc "Every subscription, for inspection."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc """
  The device subscribed at `endpoint` is showing `session_id` (`nil`: none, or
  it is hidden), as told by the channel process `pid`.
  """
  def watching(endpoint, session_id, pid, server \\ @name),
    do: GenServer.cast(server, {:watching, endpoint, session_id, pid})

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    {keys, subs} = load(path)

    state = %{
      path: path,
      keys: keys,
      subs: subs,
      # endpoint => {session_id, pid, monitor}
      watching: %{},
      deliver: Keyword.get(opts, :deliver, &WebPush.deliver/4)
    }

    state = if keys, do: state, else: save(%{state | keys: WebPush.generate_keys()})
    Phoenix.PubSub.subscribe(Loom.PubSub, Loom.Agent.turns_topic())
    {:ok, state}
  end

  @impl true
  def handle_call(:public_key, _from, state), do: {:reply, WebPush.b64(state.keys.public), state}

  def handle_call(:list, _from, state), do: {:reply, Map.values(state.subs), state}

  def handle_call({:subscribe, subscription, origin, test}, _from, state) do
    case parse(subscription, origin) do
      {:ok, sub} ->
        known = Map.get(state.subs, sub.endpoint, %{})
        sub = Map.merge(sub, %{created_at: known[:created_at] || now_iso()})
        state = save(put_in(state.subs[sub.endpoint], sub))

        if test do
          send_to(state, sub, message(sub, "loom", "Notifications are on.", nil))
        end

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:unsubscribe, endpoint}, _from, state) do
    {:reply, :ok, drop(state, endpoint)}
  end

  @impl true
  def handle_cast({:watching, endpoint, session_id, pid}, state) do
    {previous, watching} = Map.pop(state.watching, endpoint)
    if previous, do: Process.demonitor(elem(previous, 2), [:flush])

    watching =
      if is_binary(session_id),
        do: Map.put(watching, endpoint, {session_id, pid, Process.monitor(pid)}),
        else: watching

    {:noreply, %{state | watching: watching}}
  end

  def handle_cast({:gone, endpoint}, state) do
    Logger.info("Loom.Push: #{endpoint} is gone; dropping it")
    {:noreply, drop(state, endpoint)}
  end

  @impl true
  def handle_info({:turn_ended, id, summary}, state) do
    {title, body} = describe(summary)

    for {endpoint, sub} <- state.subs, not looking?(state, endpoint, id) do
      send_to(state, sub, message(sub, title, body, id))
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    watching = Map.reject(state.watching, fn {_, {_, _, r}} -> r == ref end)
    {:noreply, %{state | watching: watching}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Sending ─────────────────────────────────────────────────────────────

  defp looking?(state, endpoint, id), do: match?({^id, _, _}, state.watching[endpoint])

  defp describe(%{title: title, outcome: outcome}) do
    body =
      case outcome do
        {:ok, text} when is_binary(text) and text != "" -> snippet(text)
        {:error, message} -> "Failed: " <> snippet(message)
        _ -> "Done."
      end

    {title || "loom", body}
  end

  # Markdown read as plain text: a notification shows a line or two.
  defp snippet(text) do
    text
    |> String.replace(~r/```[^\n]*\n?/, "")
    |> String.replace(~r/[*_`#>|]+/, "")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate()
  end

  defp truncate(text) do
    if String.length(text) > @body_limit,
      do: String.slice(text, 0, @body_limit - 1) <> "…",
      else: text
  end

  defp message(sub, title, body, session_id) do
    url = if session_id, do: "#{sub.origin}/?session=#{session_id}", else: sub.origin <> "/"

    Jason.encode!(%{
      web_push: 8030,
      notification: %{
        title: title,
        body: body,
        navigate: url,
        # One notification per session: a newer turn replaces the older one.
        tag: session_id || "loom",
        data: %{session: session_id}
      }
    })
  end

  defp send_to(state, sub, payload) do
    server = self()
    deliver = state.deliver
    keys = state.keys

    Task.start(fn ->
      case deliver.(sub, payload, keys, subject(sub.origin)) do
        {:ok, status, _body} when status in 200..299 ->
          :ok

        {:ok, status, _body} when status in [404, 410] ->
          GenServer.cast(server, {:gone, sub.endpoint})

        other ->
          Logger.warning("Loom.Push: #{sub.endpoint} answered #{inspect(other)}")
      end
    end)
  end

  # Apple refuses a VAPID subject on `localhost` or plain http (BadJwtToken,
  # measured), which is what a dev server has; any real-looking contact will do.
  defp subject("https://" <> _ = origin), do: origin
  defp subject(_origin), do: "mailto:loom@example.com"

  # ── Storage ─────────────────────────────────────────────────────────────

  defp parse(
         %{
           "endpoint" => "https://" <> _ = endpoint,
           "keys" => %{"p256dh" => p256dh, "auth" => auth}
         },
         origin
       )
       when is_binary(p256dh) and is_binary(auth) and is_binary(origin) do
    with %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) <-
           URI.parse(origin),
         {:ok, _} <- Base.url_decode64(String.trim_trailing(p256dh, "="), padding: false),
         {:ok, _} <- Base.url_decode64(String.trim_trailing(auth, "="), padding: false) do
      {:ok,
       %{
         endpoint: endpoint,
         p256dh: p256dh,
         auth: auth,
         origin: String.trim_trailing(origin, "/")
       }}
    else
      _ -> :error
    end
  end

  defp parse(_subscription, _origin), do: :error

  defp drop(state, endpoint) do
    if Map.has_key?(state.subs, endpoint),
      do: save(%{state | subs: Map.delete(state.subs, endpoint)}),
      else: state
  end

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"public" => public, "private" => private} = data} <- Jason.decode(body) do
      keys = %{public: WebPush.decode!(public), private: WebPush.decode!(private)}

      subs =
        for sub <- data["subscriptions"] || [], is_binary(sub["endpoint"]), into: %{} do
          {sub["endpoint"],
           Map.new(~w(endpoint p256dh auth origin created_at)a, &{&1, sub[to_string(&1)]})}
        end

      {keys, subs}
    else
      {:error, :enoent} ->
        {nil, %{}}

      _ ->
        # Aside rather than overwritten: a new key would orphan every device.
        aside = "#{path}.bad-#{System.os_time(:second)}"
        File.rename(path, aside)
        Logger.error("Loom.Push cannot read #{path}; moved it to #{aside}")
        {nil, %{}}
    end
  end

  defp save(state) do
    body = %{
      public: WebPush.b64(state.keys.public),
      private: WebPush.b64(state.keys.private),
      subscriptions: state.subs |> Map.values() |> Enum.sort_by(& &1.created_at)
    }

    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(body, pretty: true))
    # The private key signs as this Loom.
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, state.path)
    state
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
