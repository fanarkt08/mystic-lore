import Config

config :community, MlCommunity.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "ml_community_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :community, MlCommunityWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4006")],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "yqnwhuh7FVYo9XiRx6DhmSpqgyjLinI4xIlNne0Cevf9OmiYl+8BlrXn7XMd+sHg"

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# secret interne de dev uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "dev-internal-secret-not-for-production-0123456789abcdef"
