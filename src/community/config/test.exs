import Config

# MIX_TEST_PARTITION permet de partitionner les tests en CI.
config :community, MlCommunity.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "ml_community_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :community, MlCommunityWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4106],
  secret_key_base: "BL7tXTjTKi+Ev3Y+CPlY0MheAfw1FnYDaLmHbxhGYa8xDlseuh/HEdt1z2c+XL+H",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]

# Notifications (MlShared.Notifications) : exécutées dans le processus appelant, un seul essai.
config :ml_shared, notifications_async: false, notifications_retry_delays: []
