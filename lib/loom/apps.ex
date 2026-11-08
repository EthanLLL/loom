defmodule Loom.Apps do
  @moduledoc """
  Apps: what an agent distilled out of a conversation into a plain program, so
  that using it needs no model — a page, and optionally a server behind it and
  a job that refreshes its data on a schedule.

  One process owns the registry. `~/.loom/apps.json` is the truth: read at boot,
  rewritten on every change, and pushed whole to the lobby (`"apps"`) so the
  Apps grid follows without polling. An app's code and data are its directory,
  `~/.loom/apps/<name>/`:

    * `web/` — the page, served by `LoomWeb.Apps` as it is; `web/index.html`
      must exist, and its favicon is its icon in the grid (`icon/1`)
    * `server` — a command run there on demand, listening on the unix socket
      in `$APP_SOCKET`; it gets the page's `api/*` requests
    * `job` — a command run there on `schedule` (systemd `OnCalendar`, UTC)

  ## Processes are systemd's

  Each app becomes user units, written and (re)enabled from here:

    * `app-<name>.socket` holds `.run/http.sock`; the first connection starts
      `app-<name>.service`, a `systemd-socket-proxyd` that exits after `idle`
      without one, and takes `app-<name>-server.service` down with it
    * `app-<name>-job.timer` runs `app-<name>-job.service`; `Persistent`, so a
      run missed while the host was down happens at boot

  so an app's server outlives a restart of loom, and loom never tracks a pid.
  At boot every app's units are rewritten and any other `app-*` unit removed:
  the registry, not what happens to be installed, says what runs.

  ## Who may reach it

  `auth` says, and `LoomWeb.Apps` enforces:

    * `"private"` (the default) — the signed path from `url/1`, which is how
      the user's own Loom opens it, or `Authorization: Bearer <key>` with the
      app's key (`key/1`), for a program that pushes or pulls for good
    * `"public"` — anyone, and the app does any checking itself

  A key is kept as its hash only; minting a new one revokes the old.

  There is no HTTP API. Apps are made by an agent on the node itself, over
  `bin/loom rpc` — see the `apps` skill.
  """
  use GenServer

  require Logger

  @name __MODULE__
  @persisted ~w(name title order auth key_hash server idle job schedule created_at)a
  @settable ~w(title auth server idle job schedule)a
  @auths ~w(private public)
  @salt "app"
  @max_age 60 * 60 * 24 * 30
  @cookie_salt "app cookie"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Create or change an app. `attrs` takes `:title`, `:auth`, `:server`, `:idle`,
  `:job` and `:schedule`, atom or string keys; a key given as `nil` clears it, one not
  given is left as it was. A new app goes last. Its directory must already
  hold `web/index.html`. Returns `{:ok, app}` or `{:error, reason}`.
  """
  def put(name, attrs \\ %{}, server \\ @name),
    do: GenServer.call(server, {:put, name, attrs}, 30_000)

  @doc "Every app, in order, each with the signed `url` its page opens under and its `icon`."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc "One app, or `nil`."
  def get(name, server \\ @name), do: GenServer.call(server, {:get, name})

  @doc "Remove an app: its units go, its directory to `apps/.trash/`."
  def delete(name, server \\ @name), do: GenServer.call(server, {:delete, name}, 30_000)

  @doc "Put an app at `position` (1 is first) and renumber the rest."
  def move(name, position, server \\ @name), do: GenServer.call(server, {:move, name, position})

  @doc "Run an app's job now, without waiting for its schedule; it runs in the background."
  def run(name, server \\ @name), do: GenServer.call(server, {:run, name}, 30_000)

  @doc """
  Mint a new key for a private app's `Authorization: Bearer`, revoking any
  before it: `{:ok, key}`, the only time it is seen. `key(name, nil)` revokes
  it and mints none.
  """
  def key(name, op \\ :new, server \\ @name), do: GenServer.call(server, {:key, name, op})

  @doc "Whether `key` is the one `key/1` last minted for `name`."
  def valid_key?(name, key, server \\ @name), do: GenServer.call(server, {:valid_key?, name, key})

  @doc "The path an app's page opens under: signed, so an iframe or a bookmark needs no header."
  def url(name), do: "/apps/#{name}/#{Phoenix.Token.sign(LoomWeb.Endpoint, @salt, name)}/"

  @doc "Whether `token` is one `url/1` signed for `name`, in the last 30 days."
  def valid_token?(name, token) do
    Phoenix.Token.verify(LoomWeb.Endpoint, @salt, token, max_age: @max_age) == {:ok, name}
  end

  @doc """
  The apps' own origin (`LOOM_APPS_URL`), where `LoomWeb.AppsEndpoint`
  serves them: their URLs are absolute there.
  """
  def origin, do: config(:origin)

  @doc """
  The value of the cookie a signed link sets on the apps' own origin, scoped
  to the app's path; good for 30 days from when it was last renewed.
  """
  def cookie(name), do: Phoenix.Token.sign(LoomWeb.Endpoint, @cookie_salt, name)

  @doc "Whether `value` is one `cookie/1` made for `name`, in the last 30 days."
  def valid_cookie?(name, value) do
    Phoenix.Token.verify(LoomWeb.Endpoint, @cookie_salt, value, max_age: @max_age) == {:ok, name}
  end

  def max_age, do: @max_age

  @doc """
  The files in an app's `web/` a browser fetches without its cookie to install
  it: `manifest.webmanifest`, the icons that lists, and the page's icons.
  They say what the app is called and how it looks, nothing more, so they are
  open to anyone on the apps' own origin.
  """
  def install_files(name) do
    manifest =
      with {:ok, body} <- File.read(Path.join([dir(name), "web", "manifest.webmanifest"])),
           {:ok, %{"icons" => icons}} when is_list(icons) <- Jason.decode(body) do
        for %{"src" => src} when is_binary(src) <- icons,
            rel = src |> String.trim_leading("./"),
            not String.contains?(rel, ":") and not String.starts_with?(rel, "/"),
            do: rel
      else
        _ -> []
      end

    Enum.uniq(["manifest.webmanifest" | manifest] ++ icons(name))
  end

  def root, do: config(:root) || Path.join(Loom.Agent.Store.home(), "apps")
  def dir(name), do: Path.join(root(), name)
  def path, do: config(:path) || Path.join(Loom.Agent.Store.home(), "apps.json")

  defp config(key), do: Application.get_env(:loom, __MODULE__, [])[key]

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      path: Keyword.get(opts, :path, path()),
      apps: Map.new(load(Keyword.get(opts, :path, path())), &{&1.name, &1}),
      systemd: Keyword.get(opts, :systemd, config(:systemd) != false),
      units: Keyword.get(opts, :units, config(:units) || Path.expand("~/.config/systemd/user"))
    }

    {:ok, state, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    sync_all(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:put, name, attrs}, _from, state) do
    old = state.apps[name]

    with :ok <- check_name(name),
         :ok <- check_dir(name),
         {:ok, app} <- build(old, name, attrs, state) do
      state = save(put_in(state.apps[name], app))
      install(app, state)
      {:reply, {:ok, public(app)}, broadcast(state)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, ordered(state), state}

  def handle_call({:get, name}, _from, state) do
    {:reply, state.apps[name] && public(state.apps[name]), state}
  end

  def handle_call({:delete, name}, _from, state) do
    case state.apps do
      %{^name => _} ->
        uninstall(name, state)
        trash(name)

        {:reply, :ok,
         state |> Map.update!(:apps, &Map.delete(&1, name)) |> renumber() |> save() |> broadcast()}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:move, name, position}, _from, state) when is_integer(position) do
    case state.apps do
      %{^name => app} ->
        rest = state.apps |> Map.delete(name) |> Map.values() |> Enum.sort_by(& &1.order)
        names = rest |> List.insert_at(max(position - 1, 0), app) |> Enum.map(& &1.name)

        apps =
          Map.new(Enum.with_index(names, 1), fn {n, i} -> {n, %{state.apps[n] | order: i}} end)

        {:reply, :ok, %{state | apps: apps} |> save() |> broadcast()}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:key, name, op}, _from, state) do
    case state.apps do
      %{^name => app} ->
        {key, hash} =
          if op == nil do
            {nil, nil}
          else
            key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
            {key, hash(key)}
          end

        state = save(put_in(state.apps[name], %{app | key_hash: hash}))
        {:reply, if(key, do: {:ok, key}, else: :ok), state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:valid_key?, name, key}, _from, state) do
    valid =
      case state.apps do
        %{^name => %{key_hash: hash}} when is_binary(hash) and is_binary(key) ->
          Plug.Crypto.secure_compare(hash(key), hash)

        _ ->
          false
      end

    {:reply, valid, state}
  end

  def handle_call({:run, name}, _from, state) do
    case state.apps do
      %{^name => %{job: job}} when is_binary(job) ->
        {:reply, systemctl(state, ["start", "--no-block", "app-#{name}-job.service"]), state}

      %{^name => _} ->
        {:reply, {:error, :no_job}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # ── Apps ────────────────────────────────────────────────────────────────

  defp check_name(name) when is_binary(name) do
    if name =~ ~r/\A[a-z0-9][a-z0-9-]{0,39}\z/,
      do: :ok,
      else: {:error, "name: lowercase letters, digits and -, at most 40"}
  end

  defp check_name(_), do: {:error, "name must be a string"}

  defp check_dir(name) do
    if File.regular?(Path.join([dir(name), "web", "index.html"])),
      do: :ok,
      else: {:error, "#{dir(name)}/web/index.html does not exist"}
  end

  defp build(old, name, attrs, state) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with [] <- Map.keys(attrs) -- Enum.map(@settable, &to_string/1) do
      base =
        old ||
          %{
            name: name,
            title: name,
            auth: "private",
            key_hash: nil,
            order:
              (state.apps |> Map.values() |> Enum.map(& &1.order) |> Enum.max(fn -> 0 end)) + 1,
            server: nil,
            idle: nil,
            job: nil,
            schedule: nil,
            created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          }

      app = Enum.reduce(@settable, base, &take(&2, &1, attrs))
      app = %{app | title: app.title || name, auth: app.auth || "private"}

      cond do
        app.auth not in @auths ->
          {:error, "auth: private or public"}

        app.job != nil and app.schedule == nil ->
          {:error, "a job needs a schedule"}

        app.schedule != nil and app.job == nil ->
          {:error, "a schedule needs a job"}

        app.schedule != nil and not calendar?(app.schedule, state) ->
          {:error, "schedule: not a systemd calendar expression"}

        true ->
          {:ok, app}
      end
    else
      unknown -> {:error, "unknown keys: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp take(app, key, attrs) do
    case Map.fetch(attrs, to_string(key)) do
      {:ok, nil} -> Map.put(app, key, nil)
      {:ok, v} when is_binary(v) and v != "" -> Map.put(app, key, v)
      {:ok, _} -> app
      :error -> app
    end
  end

  defp calendar?(expr, %{systemd: false}), do: expr != ""

  defp calendar?(expr, _state) do
    match?({_, 0}, System.cmd("systemd-analyze", ["calendar", expr], stderr_to_stdout: true))
  end

  defp ordered(state) do
    state.apps |> Map.values() |> Enum.sort_by(&{&1.order, &1.name}) |> Enum.map(&public/1)
  end

  defp public(app) do
    path = if app.auth == "public", do: "/apps/#{app.name}/", else: url(app.name)
    url = origin() <> path
    icon = icon(app.name)

    app
    |> Map.delete(:key_hash)
    |> Map.merge(%{url: url, icon: icon && url <> icon, key: app.key_hash != nil})
  end

  defp hash(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  # The page's own favicon, so one file is both: the first `<link rel="icon">`
  # (or `apple-touch-icon`, which iOS puts on the home screen) in
  # `web/index.html` that points at a file in `web/`, else a `favicon.*` there.
  # Read at each list, as the page is the agent's to rewrite at any time.
  defp icon(name), do: List.first(icons(name))

  defp icons(name) do
    web = Path.join(dir(name), "web")
    html = File.read(Path.join(web, "index.html"))

    linked =
      with {:ok, html} <- html do
        for [tag] <- Regex.scan(~r/<link\b[^>]*>/i, html),
            Regex.match?(~r/\brel\s*=\s*["'][^"']*\bicon\b/i, tag),
            [_, href] <- [Regex.run(~r/\bhref\s*=\s*["']([^"'#?]+)/i, tag)],
            # A Vite build may write `/favicon.svg`: still a file in web/.
            rel = href |> String.trim_leading("./") |> String.trim_leading("/"),
            not String.contains?(rel, ":"),
            do: rel
      else
        _ -> []
      end

    Enum.filter(Enum.uniq(linked ++ ~w(favicon.svg favicon.png favicon.ico)), fn rel ->
      path = Path.expand(Path.join(web, rel))
      String.starts_with?(path, web <> "/") and File.regular?(path)
    end)
  end

  defp renumber(state) do
    names = state.apps |> Map.values() |> Enum.sort_by(& &1.order) |> Enum.map(& &1.name)

    %{
      state
      | apps:
          Map.new(Enum.with_index(names, 1), fn {n, i} -> {n, %{state.apps[n] | order: i}} end)
    }
  end

  # Kept, not deleted: an app's data can be all there is of something.
  defp trash(name) do
    from = dir(name)

    if File.exists?(from) do
      to = Path.join([root(), ".trash", "#{name}-#{System.os_time(:second)}"])
      File.mkdir_p!(Path.dirname(to))
      File.rename!(from, to)
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Loom.PubSub, Loom.Agent.lobby_topic(), {:apps, ordered(state)})
    state
  end

  # ── systemd ─────────────────────────────────────────────────────────────

  # Every app's units as the registry has them, and no others.
  defp sync_all(state) do
    File.mkdir_p!(state.units)
    wanted = state.apps |> Map.values() |> Enum.flat_map(&write_units(&1, state))

    for file <- File.ls!(state.units), String.starts_with?(file, "app-"), file not in wanted do
      systemctl(state, ["disable", "--now", file])
      File.rm(Path.join(state.units, file))
    end

    systemctl(state, ["daemon-reload"])
    Enum.each(Map.values(state.apps), &enable(&1, state))
  end

  # A change: the new units in, the old processes out, so the next request or
  # tick runs what was just put.
  defp install(app, state) do
    uninstall(app.name, state)
    write_units(app, state)
    systemctl(state, ["daemon-reload"])
    enable(app, state)
  end

  defp uninstall(name, state) do
    units =
      for s <- ["", "-server", "-job"],
          t <- [".socket", ".service", ".timer"],
          do: "app-#{name}#{s}#{t}"

    present = Enum.filter(units, &File.exists?(Path.join(state.units, &1)))

    if present != [] do
      systemctl(state, ["disable", "--now" | present])
      Enum.each(present, &File.rm(Path.join(state.units, &1)))
      systemctl(state, ["daemon-reload"])
    end
  end

  defp enable(app, state) do
    if app.server, do: systemctl(state, ["enable", "--now", "app-#{app.name}.socket"])
    if app.job, do: systemctl(state, ["enable", "--now", "app-#{app.name}-job.timer"])
  end

  # Returns the file names written.
  defp write_units(app, state) do
    dir = dir(app.name)
    run = Path.join(dir, ".run")
    File.mkdir_p!(run)
    path = "PATH=" <> (System.get_env("PATH") || "/usr/bin:/bin")
    n = app.name

    server =
      if app.server do
        [
          {"app-#{n}.socket",
           """
           [Unit]
           Description=loom app #{n}

           [Socket]
           ListenStream=#{run}/http.sock
           SocketMode=0600

           [Install]
           WantedBy=sockets.target
           """},
          {"app-#{n}.service",
           """
           [Unit]
           Description=loom app #{n} (proxy)
           Requires=app-#{n}-server.service
           After=app-#{n}-server.service

           [Service]
           ExecStart=/usr/lib/systemd/systemd-socket-proxyd --exit-idle-time=#{app.idle || "10min"} #{run}/app.sock
           """},
          {"app-#{n}-server.service",
           """
           [Unit]
           Description=loom app #{n} (server)
           StopWhenUnneeded=yes

           [Service]
           WorkingDirectory=#{dir}
           Environment=APP_SOCKET=#{run}/app.sock
           Environment="#{path}"
           ExecStartPre=/bin/rm -f #{run}/app.sock
           ExecStart=/bin/sh -c #{shell_quote("exec " <> app.server)}
           # Ready once the socket exists: the proxy connects as soon as this returns.
           ExecStartPost=/bin/sh -c 'i=0; until [ -S #{run}/app.sock ]; do i=$$((i+1)); [ $$i -lt 250 ] || exit 1; sleep 0.02; done'
           MemoryMax=256M
           """}
        ]
      else
        []
      end

    job =
      if app.job do
        [
          {"app-#{n}-job.service",
           """
           [Unit]
           Description=loom app #{n} (job)

           [Service]
           Type=oneshot
           WorkingDirectory=#{dir}
           Environment="#{path}"
           ExecStart=/bin/sh -c #{shell_quote("exec " <> app.job)}
           TimeoutStartSec=30min
           """},
          {"app-#{n}-job.timer",
           """
           [Unit]
           Description=loom app #{n} (schedule)

           [Timer]
           OnCalendar=#{app.schedule}
           Persistent=true

           [Install]
           WantedBy=timers.target
           """}
        ]
      else
        []
      end

    for {file, body} <- server ++ job do
      File.write!(Path.join(state.units, file), body)
      file
    end
  end

  # systemd's own quoting for one argument: double quotes, with `\`, `"` and
  # `$` (which systemd would expand) escaped, and `%` doubled.
  defp shell_quote(s) do
    ~s(") <>
      (s
       |> String.replace("\\", "\\\\")
       |> String.replace(~s("), ~s(\\"))
       |> String.replace("$", "$$")
       |> String.replace("%", "%%")) <> ~s(")
  end

  defp systemctl(%{systemd: false}, _args), do: :ok

  defp systemctl(_state, args) do
    env = [{"XDG_RUNTIME_DIR", System.get_env("XDG_RUNTIME_DIR") || "/run/user/#{uid()}"}]

    case System.cmd("systemctl", ["--user" | args], env: env, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, code} ->
        Logger.warning(
          "apps: systemctl #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"
        )

        {:error, String.trim(out)}
    end
  end

  defp uid do
    {out, 0} = System.cmd("id", ["-u"])
    String.trim(out)
  end

  # ── Persistence ─────────────────────────────────────────────────────────

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"apps" => apps}} <- Jason.decode(body) do
      for a <- apps, is_map(a), is_binary(a["name"]) do
        app = Map.new(@persisted, &{&1, a[to_string(&1)]})
        %{app | auth: app.auth || "private"}
      end
    else
      {:error, :enoent} ->
        []

      other ->
        Logger.error("apps: cannot read #{path}: #{inspect(other)}")
        []
    end
  end

  defp save(state) do
    apps =
      state.apps
      |> Map.values()
      |> Enum.sort_by(& &1.order)
      |> Enum.map(&Map.take(&1, @persisted))

    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(%{apps: apps}, pretty: true))
    File.rename!(tmp, state.path)
    state
  end
end
