import Config

# TLS is terminated upstream at CloudFront; nginx → Phoenix is plain HTTP.
# So no force_ssl / HSTS here, and check_origin is disabled (requests arrive
# proxied, with rewritten Host/Origin headers).

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
