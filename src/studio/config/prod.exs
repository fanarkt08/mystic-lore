import Config

# Service interne appelé en HTTP (jeton interne signé) : pas de `force_ssl` (TLS terminé en bordure).

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
