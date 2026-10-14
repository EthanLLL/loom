import Config

config :loom, :password, "test-password"

# Each test owns its session data under a temp dir, so the boot-time restore
# would only race with that. Tests that exercise restore drive it directly.
config :loom, :restore_agents, false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :loom, LoomWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "VzA3sG+8Akz5Fqb3nrSRbR1nYdOqxDUe+C0WVeltx5CWLkUBeHm4nY8EcosHe6pv",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# No real `codex app-server`: the suite drives the JSON-RPC protocol directly,
# and spawning one would make every run slow and dependent on a working login.
config :loom, :codex_server, false
