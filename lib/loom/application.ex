defmodule Loom.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LoomWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:loom, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Loom.PubSub},
      {Registry, keys: :unique, name: Loom.Terminal.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Loom.Terminal.SessionSupervisor},
      Loom.Terminal.Layout,
      # Agent sessions: one GenServer each, plus a shared pool for the tasks
      # they spawn (model requests and tool runs). The tasks live under their
      # own supervisor rather than linked to the session, so a tool that
      # crashes cannot take the conversation down with it.
      {Registry, keys: :unique, name: Loom.Agent.Registry},
      # Sessions are `restart: :transient`, so a crashed one is restarted and
      # resumes from disk. The default intensity (3 restarts / 5s) applies to
      # the supervisor as a whole, which means a few unrelated sessions
      # crashing close together would take this supervisor — and therefore
      # *every* live session — down with them. Raised so one bad session
      # cannot cascade; a session that crashes in a tight loop still
      # eventually trips it, which is the intended backstop.
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Loom.Agent.SessionSupervisor,
       max_restarts: 20,
       max_seconds: 5},
      {Task.Supervisor, name: Loom.Agent.TaskSupervisor},
      # Owns the one shared `codex app-server` for the whole node and keeps it
      # running. It respawns the OS process itself, with backoff, rather than
      # dying and being restarted here — a `codex` that fails immediately
      # (missing binary, expired login) would otherwise crash-loop and take the
      # application down with it. Disabled under test, where the protocol is
      # driven directly.
      {Loom.Agent.Codex.Server, spawn: Application.get_env(:loom, :codex_server, true)},
      # Must come after the registry and the session supervisor it populates.
      # Disabled under test so suites start from a clean slate.
      {Loom.Agent.Bootstrap, enabled: Application.get_env(:loom, :restore_agents, true)},
      # Scheduled prompts. After the bootstrap, so a job due at boot finds its
      # session already restored.
      Loom.Cron,
      # The user's own machines that agents can run commands on.
      Loom.Nodes,
      # Notifications on the user's devices when a turn ends.
      Loom.Push,
      # Restarts the node once every session is idle, on request. See its doc.
      Loom.Restarter,
      # Start to serve requests, typically the last entry
      LoomWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Loom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LoomWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
