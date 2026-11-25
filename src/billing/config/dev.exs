import Config

config :billing, MlBilling.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "ml_billing_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :billing, MlBillingWeb.Endpoint,
  # Loopback only: internal service (only `web` is exposed to browsers).
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4003")],
  check_origin: false,
  code_reloader: true,
  # JSON errors even in dev (consumed by services, not browsers); details stay in the log.
  debug_errors: false,
  secret_key_base: "+upjBwPpCG20L475jN5Gb4rYI9jg9ctS/ofzhwyPa6o6vb0xKsddtTQ9bv97n/zq"

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# secret interne de dev uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "dev-internal-secret-not-for-production-0123456789abcdef"
