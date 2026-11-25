import Config

# MIX_TEST_PARTITION permet de partitionner les tests en CI.
config :notifications, MlNotifications.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "ml_notifications_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :notifications, MlNotificationsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4108],
  secret_key_base: "Wn7Tq2Lx9Vb4Hs1Kd8Pz3Rm6Yc0Jf5Ga2Ue7Io4Nk9Sw1Qh6Xt3Bv8Ml0Dr5Ey2C",
  server: false

# Tâches insérées mais exécutées seulement à la demande (Oban.Testing.perform_job/3) ; pas de cron.
config :notifications, Oban, testing: :manual

config :notifications, email_delay_seconds: 0

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]
