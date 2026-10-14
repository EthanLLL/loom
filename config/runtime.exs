import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/loom start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :loom, LoomWeb.Endpoint, server: true
end

config :loom, LoomWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Everything loom owns on disk — session headers, transcripts, and the files a
# user attached — lives here. Under the user's home rather than the release,
# because a deploy replaces `priv/`.
config :loom, :home, System.get_env("LOOM_HOME") || Path.expand("~/.loom")

# Agent sessions run Claude Code or Codex as a child process; loom runs no
# model requests of its own, so there is no API key or region here. Both CLIs
# must be on PATH and already logged in — they decide which model and which
# credentials to use. Applies to every environment.
config :loom, Loom.Agent,
  # Override only to pin a specific binary (an absolute path, a wrapper).
  claude_cli: System.get_env("LOOM_CLAUDE_CLI") || "claude",
  codex_cli: System.get_env("LOOM_CODEX_CLI") || "codex",
  # Working directory for new sessions. Sessions have no project root of their
  # own: which project is being worked on is a fact in the conversation, and
  # the model composes absolute paths from it.
  workspace: System.get_env("LOOM_WORKSPACE")

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :loom, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :loom,
         :password,
         System.get_env("LOOM_PASSWORD") ||
           raise("environment variable LOOM_PASSWORD is missing.")

  config :loom, LoomWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind only to loopback: nginx on the same host proxies to us. Nothing
      # should hit Phoenix directly from outside.
      ip: {127, 0, 0, 1},
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    # TLS is terminated at CloudFront and the request is proxied through nginx,
    # so the Origin/Host headers won't match our own host. Accept all origins.
    check_origin: false,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :loom, LoomWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :loom, LoomWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
