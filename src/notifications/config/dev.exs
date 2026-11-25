import Config

config :notifications, MlNotifications.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "ml_notifications_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :notifications, MlNotificationsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4008")],
  code_reloader: true,
  # erreurs JSON même en dev (lues par des services, pas par un navigateur) ; le détail reste dans le journal
  debug_errors: false,
  secret_key_base: "fZ3H0Ju9a1Q7kVt2Wq6mR8sY4dXo5LpB+NcE1gTzKhJ0iAvU3rMwS7yOq9bD2xGe"

# En dev, un e-mail facultatif part 10 s après l'événement (60 s par défaut) : la boîte de dev le montre vite.
config :notifications, email_delay_seconds: 10

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# secret interne de dev uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "dev-internal-secret-not-for-production-0123456789abcdef"
