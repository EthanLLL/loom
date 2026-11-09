defmodule Loom.Apps do
  @moduledoc """
  Apps: what an agent distilled out of a conversation into a plain program, so
  that using it needs no model — a page, and optionally a server behind it and
  a job that refreshes its data on a schedule.

  Loom is their registry and nothing more: it writes what runs them and steps
  out of the way. `~/.loom/apps.json` is the truth: read at boot, rewritten on
  every change, and pushed whole to the lobby (`"apps"`) so the Apps grid
  follows without polling. An app's code and data are its directory,
  `~/.loom/apps/<name>/`:

    * `web/` — the page; its favicon is its icon in the grid (`icon/1`)
    * `server` — a command run there on demand, listening on the unix socket
      in `$APP_SOCKET`, or on `$PORT` when the app has a `port`
    * `job` — a command run there on `schedule` (systemd `OnCalendar`, UTC)

  and `proxy` says what the server gets: `"api"` (the default) its `api/*`,
  with `web/index.html` the rest; `"all"`, everything — a whole site, such as
  one cloned from elsewhere, with no `web/` needed.

  ## Serving is Caddy's

  `caddy.json` beside `apps.json` is Caddy's whole config, written from the
  registry on every change and at boot, then loaded with `caddy reload` over
  Caddy's admin socket. Caddy runs as the user unit `loom-apps.service`,
  starting from that file, so the apps are served whether or not loom is up.
  Each app is `/apps/<name>/` on the apps' origin (`origin/0`): `web/` as
  files, the server behind a reverse proxy — HTTP/2, WebSocket and SSE pass
  as they are — and a reply with `x-loom-file: <path in the app's directory>`
  answered with that file from disk, with `Range`, like nginx's
  `X-Accel-Redirect`. An `"api"` app's server sees `/api/…`; an `"all"`
  app's sees the full path, with `X-Forwarded-Prefix: /apps/<name>`.

  There is no access control here: an app is open to whoever reaches the
  apps' origin, and checks who is asking itself if it must.

  ## Processes are systemd's

  Each app becomes user units, written and (re)enabled from here:

    * `app-<name>.socket` holds `.run/http.sock`; the first connection starts
      `app-<name>.service`, a `systemd-socket-proxyd` that exits after `idle`
      without one, and takes `app-<name>_server.service` down with it; bound
      to the server, so a server that dies takes the proxy with it and the
      next connection starts both afresh
    * `app-<name>_job.timer` runs `app-<name>_job.service`; `Persistent`, so a
      run missed while the host was down happens at boot

  The suffixes are joined with `_`, which a name cannot contain, so no app's
  units can be another's: `x`'s job is `app-x_job`, an app called `x-job` is
  `app-x-job`.

  so an app's server outlives a restart of loom, and loom never tracks a pid.
  At boot every app's units are rewritten and any other `app-*` unit removed:
  the registry, not what happens to be installed, says what runs.

  There is no HTTP API. Apps are made by an agent on the node itself, over
  `bin/loom rpc` — see the `apps` skill.
  """
  use GenServer

  require Logger

  @name __MODULE__
  @persisted ~w(name title order proxy port server idle job schedule created_at)a
  @settable ~w(title proxy port server idle job schedule)a
  @proxies ~w(api all)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Create or change an app. `attrs` takes `:title`, `:proxy`, `:port`,
  `:server`, `:idle`, `:job` and `:schedule`, atom or string keys; a key given
  as `nil` clears it, one not given is left as it was. A new app goes last. Its
  directory must already hold `web/index.html`, unless its `proxy` is `"all"`.
  Returns `{:ok, app}` or `{:error, reason}`.
  """
  def put(name, attrs \\ %{}, server \\ @name),
    do: GenServer.call(server, {:put, name, attrs}, 30_000)

  @doc "Every app, in order, each with the `url` its page opens under and its `icon`."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc "One app, or `nil`."
  def get(name, server \\ @name), do: GenServer.call(server, {:get, name})

  @doc "Remove an app: its units go, its directory to `apps/.trash/`."
  def delete(name, server \\ @name), do: GenServer.call(server, {:delete, name}, 30_000)

  @doc "Put an app at `position` (1 is first) and renumber the rest."
  def move(name, position, server \\ @name), do: GenServer.call(server, {:move, name, position})

  @doc "Run an app's job now, without waiting for its schedule; it runs in the background."
  def run(name, server \\ @name), do: GenServer.call(server, {:run, name}, 30_000)

  @doc "The apps' own origin (`LOOM_APPS_URL`): their URLs are absolute there."
  def origin, do: config(:origin)

  def root, do: config(:root) || Path.join(Loom.Agent.Store.home(), "apps")
  def dir(name), do: Path.join(root(), name)
  def path, do: config(:path) || Path.join(Loom.Agent.Store.home(), "apps.json")
  def caddy_path, do: Path.join(Path.dirname(path()), "caddy.json")

  defp config(key), do: Application.get_env(:loom, __MODULE__, [])[key]

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())

    systemd = Keyword.get(opts, :systemd, config(:systemd) != false)

    state = %{
      path: path,
      caddy: Path.join(Path.dirname(path), "caddy.json"),
      apps: Map.new(load(path), &{&1.name, &1}),
      systemd: systemd,
      units: Keyword.get(opts, :units, config(:units) || units_dir(systemd, path))
    }

    {:ok, state, {:continue, :sync}}
  end

  # Without systemd (a dev server beside the real loom) the units are written
  # next to its own apps.json: the boot sync removes every `app-*` unit it does
  # not know, which in the user's directory would be the real loom's.
  defp units_dir(true, _path), do: Path.expand("~/.config/systemd/user")
  defp units_dir(false, path), do: Path.join(Path.dirname(path), "units")

  @impl true
  def handle_continue(:sync, state) do
    sync_all(state)
    serve(state, :boot)
    {:noreply, state}
  end

  @impl true
  def handle_call({:put, name, attrs}, _from, state) do
    old = state.apps[name]

    with :ok <- check_name(name),
         {:ok, app} <- build(old, name, attrs, state),
         :ok <- check_dir(app) do
      state = save(put_in(state.apps[name], app))
      install(app, state)
      serve(state)
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
        state = state |> Map.update!(:apps, &Map.delete(&1, name)) |> renumber() |> save()
        serve(state)
        {:reply, :ok, broadcast(state)}

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

  def handle_call({:run, name}, _from, state) do
    case state.apps do
      %{^name => %{job: job}} when is_binary(job) ->
        {:reply, systemctl(state, ["start", "--no-block", "app-#{name}_job.service"]), state}

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

  defp check_dir(%{proxy: "all"}), do: :ok

  defp check_dir(%{name: name}) do
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
            proxy: "api",
            port: nil,
            order:
              (state.apps |> Map.values() |> Enum.map(& &1.order) |> Enum.max(fn -> 0 end)) + 1,
            server: nil,
            idle: nil,
            job: nil,
            schedule: nil,
            created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          }

      app = Enum.reduce(@settable, base, &take(&2, &1, attrs))
      app = %{app | title: app.title || name, proxy: app.proxy || "api"}
      taken = for {n, a} <- state.apps, n != name, a.port != nil, do: a.port

      cond do
        app.proxy not in @proxies ->
          {:error, "proxy: api or all"}

        app.proxy == "all" and app.server == nil ->
          {:error, "proxy all needs a server"}

        app.port != nil and app.server == nil ->
          {:error, "a port needs a server"}

        app.port != nil and not (is_integer(app.port) and app.port in 1024..65535) ->
          {:error, "port: an integer from 1024 to 65535"}

        app.port in taken ->
          {:error, "port #{app.port} is another app's"}

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
      {:ok, v} when key == :port -> Map.put(app, key, v)
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
    url = "#{origin()}/apps/#{app.name}/"
    icon = icon(app.name)
    Map.merge(app, %{url: url, icon: icon && url <> icon})
  end

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
    written = state.apps |> Map.values() |> Enum.flat_map(&write_units(&1, state))
    wanted = Enum.map(written, &elem(&1, 0))

    for file <- File.ls!(state.units), String.starts_with?(file, "app-"), file not in wanted do
      systemctl(state, ["disable", "--now", file])
      File.rm(Path.join(state.units, file))
    end

    systemctl(state, ["daemon-reload"])
    Enum.each(Map.values(state.apps), &enable(&1, state))

    # A running proxy whose unit changed (a deploy that changes how units are
    # written) still forwards to what it was started with. Stopped, the
    # socket starts the new one at the next connection. An unchanged one is
    # left alone, so open connections survive a restart of loom.
    for {file, true} <- written, proxy?(file), do: systemctl(state, ["stop", file])
  end

  defp proxy?(file), do: String.ends_with?(file, ".service") and not String.contains?(file, "_")

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
      for s <- ["", "_server", "_job"],
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
    if app.job, do: systemctl(state, ["enable", "--now", "app-#{app.name}_job.timer"])
  end

  # Returns `{file, changed?}` for each unit written.
  defp write_units(app, state) do
    dir = dir(app.name)
    run = Path.join(dir, ".run")
    File.mkdir_p!(run)
    path = "PATH=" <> (System.get_env("PATH") || "/usr/bin:/bin")
    n = app.name

    {target, port_env, ready} =
      if app.port,
        do:
          {"127.0.0.1:#{app.port}", "\nEnvironment=PORT=#{app.port}",
           "(exec 3<>/dev/tcp/127.0.0.1/#{app.port}) 2>/dev/null"},
        else: {"#{run}/app.sock", "", "[ -S #{run}/app.sock ]"}

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
           BindsTo=app-#{n}_server.service
           After=app-#{n}_server.service

           [Service]
           ExecStart=/usr/lib/systemd/systemd-socket-proxyd --exit-idle-time=#{app.idle || "10min"} #{target}
           """},
          {"app-#{n}_server.service",
           """
           [Unit]
           Description=loom app #{n} (server)
           StopWhenUnneeded=yes

           [Service]
           WorkingDirectory=#{dir}
           Environment=APP_SOCKET=#{run}/app.sock#{port_env}
           Environment="#{path}"
           ExecStartPre=/bin/rm -f #{run}/app.sock
           ExecStart=/bin/sh -c #{shell_quote("exec " <> app.server)}
           # Ready once it listens: the proxy connects as soon as this returns.
           ExecStartPost=/bin/bash -c 'i=0; until #{ready}; do i=$$((i+1)); [ $$i -lt 1500 ] || exit 1; sleep 0.02; done'
           MemoryMax=256M
           """}
        ]
      else
        []
      end

    job =
      if app.job do
        [
          {"app-#{n}_job.service",
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
          {"app-#{n}_job.timer",
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
      path = Path.join(state.units, file)
      changed = File.read(path) != {:ok, body}
      if changed, do: File.write!(path, body)
      {file, changed}
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

  # ── Caddy ───────────────────────────────────────────────────────────────

  # The registry as Caddy's config, then Caddy told to load it; at boot, its
  # unit too, started if it is not running. The file is written first, so a
  # Caddy that starts later starts from what is current.
  defp serve(state, at \\ :change)
  defp serve(%{systemd: false}, _at), do: :ok

  defp serve(state, at) do
    File.write!(state.caddy <> ".tmp", Jason.encode_to_iodata!(caddy_config(state), pretty: true))
    File.rename!(state.caddy <> ".tmp", state.caddy)

    cond do
      caddy() == nil ->
        Logger.warning("apps: no caddy on PATH, so the apps are not served")

      at == :boot ->
        File.write!(Path.join(state.units, "loom-apps.service"), caddy_unit(state))
        systemctl(state, ["daemon-reload"])
        systemctl(state, ["enable", "--now", "loom-apps.service"])
        reload(state)

      true ->
        reload(state)
    end
  end

  defp reload(state) do
    case System.cmd(caddy(), ["reload", "--force", "--config", state.caddy],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, code} ->
        Logger.warning(
          "apps: caddy reload exited #{code}: #{out |> String.trim() |> String.slice(-500, 500)}"
        )
    end
  end

  defp caddy, do: config(:caddy) || System.find_executable("caddy")

  defp caddy_unit(state) do
    """
    [Unit]
    Description=loom apps (Caddy)

    [Service]
    ExecStart=#{caddy()} run --config #{state.caddy}
    Restart=always
    RestartSec=2

    [Install]
    WantedBy=default.target
    """
  end

  @doc false
  def caddy_config(state) do
    apps = state.apps |> Map.values() |> Enum.sort_by(& &1.name)
    vendor = Application.app_dir(:loom, "priv/static/vendor")

    %{
      admin: %{listen: "unix/#{Path.join(Path.dirname(state.caddy), "caddy-admin.sock")}|0600"},
      logging: %{logs: %{default: %{level: "WARN"}}},
      apps: %{
        http: %{
          servers: %{
            apps: %{
              listen: [config(:listen) || "127.0.0.1:5000"],
              automatic_https: %{disable: true},
              routes:
                [
                  # The libraries loom offers pages it serves, at the same path:
                  # an app or a copied deck that links `/vendor/reveal.js/…` works.
                  %{
                    match: [%{path: ["/vendor/*"]}],
                    terminal: true,
                    handle: [
                      %{handler: "rewrite", strip_path_prefix: "/vendor"},
                      %{handler: "file_server", root: vendor}
                    ]
                  }
                ] ++
                  Enum.map(apps, &route/1) ++
                  [
                    %{
                      handle: [%{handler: "static_response", status_code: 404, body: "not found"}]
                    }
                  ]
            }
          }
        }
      }
    }
  end

  defp route(app) do
    prefix = "/apps/#{app.name}"
    dir = dir(app.name)

    rest =
      case app do
        %{proxy: "all"} ->
          [%{handle: [proxy(app, dir)]}]

        %{server: nil} ->
          [%{handle: files(prefix, dir)}]

        _ ->
          [
            %{
              match: [%{path: ["#{prefix}/api/*"]}],
              terminal: true,
              handle: [%{handler: "rewrite", strip_path_prefix: prefix}, proxy(app, dir)]
            },
            %{handle: files(prefix, dir)}
          ]
      end

    %{
      match: [%{path: [prefix, prefix <> "/*"]}],
      terminal: true,
      handle: [
        %{
          handler: "subroute",
          routes:
            [
              %{
                handle: [
                  %{
                    handler: "headers",
                    response: %{
                      set: %{
                        "X-Content-Type-Options" => ["nosniff"],
                        "Referrer-Policy" => ["no-referrer"]
                      }
                    }
                  },
                  # Unless the app says otherwise; `no-transform` keeps
                  # Cloudflare from injecting its analytics beacon.
                  %{
                    handler: "headers",
                    response: %{
                      set: %{"Cache-Control" => ["no-cache, no-transform"]},
                      deferred: true,
                      require: %{headers: %{"Cache-Control" => nil}}
                    }
                  }
                ]
              },
              # Without the trailing slash the page's relative URLs would miss.
              %{
                match: [%{path: [prefix]}],
                terminal: true,
                handle: [
                  %{
                    handler: "static_response",
                    status_code: 301,
                    headers: %{"Location" => [prefix <> "/"]}
                  }
                ]
              }
            ] ++ rest
        }
      ]
    }
  end

  defp files(prefix, dir) do
    [
      %{handler: "rewrite", strip_path_prefix: prefix},
      %{handler: "file_server", root: Path.join(dir, "web")}
    ]
  end

  # `.run/http.sock` is the socket systemd holds; the first request starts the
  # server behind it.
  defp proxy(app, dir) do
    %{
      handler: "reverse_proxy",
      upstreams: [%{dial: "unix/#{Path.join([dir, ".run", "http.sock"])}"}],
      flush_interval: -1,
      headers: %{request: %{set: %{"X-Forwarded-Prefix" => ["/apps/#{app.name}"]}}},
      handle_response: [
        %{match: %{headers: %{"X-Loom-File" => ["/*"]}}, routes: [%{handle: loom_file(dir, "")}]},
        %{
          match: %{headers: %{"X-Loom-File" => ["*"]}},
          routes: [%{handle: loom_file(dir, dir <> "/")}]
        }
      ]
    }
  end

  # The file the reply names, inside the app's directory only: the path is
  # often built from a request, and a slip there should be a 404, not
  # someone's ~/.ssh. A path, so URL-encoded where it is not plain.
  defp loom_file(dir, base) do
    [
      %{handler: "copy_response_headers", exclude: ["X-Loom-File", "Content-Length"]},
      %{handler: "rewrite", uri: base <> "{http.reverse_proxy.header.X-Loom-File}"},
      %{
        handler: "subroute",
        routes: [
          %{
            match: [%{path: [dir <> "/*"]}],
            handle: [%{handler: "file_server", root: "/"}]
          },
          %{
            handle: [
              %{
                handler: "static_response",
                status_code: 404,
                body: "x-loom-file: no such file in the app"
              }
            ]
          }
        ]
      }
    ]
  end

  # ── Persistence ─────────────────────────────────────────────────────────

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"apps" => apps}} <- Jason.decode(body) do
      for a <- apps, is_map(a), is_binary(a["name"]) do
        app = Map.new(@persisted, &{&1, a[to_string(&1)]})
        %{app | proxy: app.proxy || "api"}
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
