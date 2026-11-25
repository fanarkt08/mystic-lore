import Config

config :social, MlSocial.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "ml_social_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :social, MlSocialWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4004")],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "zgJ9p7vPb4yFyN+b2G/5ha0IzIKALvtpqh6/P0nHJqWv+NLgK0V5RArN73iYx2Dm"

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# Pièces jointes déposées (jamais servies statiquement ; web les relaie) ; SOCIAL_STORAGE_DIR la remplace.
config :social, storage_dir: Path.expand("../priv/storage", __DIR__)

# secret interne de dev uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "dev-internal-secret-not-for-production-0123456789abcdef"
