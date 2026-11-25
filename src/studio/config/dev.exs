import Config

config :studio, MlStudio.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "ml_studio_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Private storage of the images (never served statically); STUDIO_STORAGE_DIR overrides it.
config :studio, storage_dir: Path.expand("../priv/storage", __DIR__)

config :studio, MlStudioWeb.Endpoint,
  # Loopback only: internal service (only `web` is exposed to browsers).
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4007")],
  check_origin: false,
  code_reloader: true,
  # JSON errors even in dev (consumed by services, not browsers); details stay in the log.
  debug_errors: false,
  secret_key_base: "dljU+tXHb0WiAbrJe58IjRDxJjEYqtSWBMs6IHYchw219Li1heX3ctJSWu3RGcPZ"

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# secret interne de dev uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "dev-internal-secret-not-for-production-0123456789abcdef"
