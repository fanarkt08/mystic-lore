import Config

# Service interne : `force_ssl` casserait les appels internes, le TLS du webhook Stripe se termine au proxy.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
