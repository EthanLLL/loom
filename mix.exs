defmodule Loom.MixProject do
  use Mix.Project

  def project do
    [
      app: :loom,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Loom.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:expty, "~> 0.2.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "cmd --cd frontend pnpm install"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],

      # Build the frontend into `priv/static`, where `Plug.Static` serves it
      # from. Run before `mix release`: the release copies `priv` as it finds
      # it, so an unbuilt frontend ships as a release that serves no UI.
      "assets.deploy": [
        "cmd --cd frontend pnpm install --frozen-lockfile",
        "cmd --cd frontend pnpm build",
        # Replace rather than merge: Vite fingerprints filenames, so a merge
        # accumulates every asset of every past build in the release forever.
        "cmd rm -rf priv/static/assets priv/static/fonts priv/static/index.html priv/static/vendor",
        "cmd cp -R frontend/dist/. priv/static/"
      ]
    ]
  end
end
