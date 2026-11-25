import Config

# MIX_TEST_PARTITION permet de partitionner les tests en CI.
config :social, MlSocial.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "ml_social_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :social, MlSocialWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4104],
  secret_key_base: "k63WpiwBh7T2KOL/OEJnDAEJ+uDWTcAU1w6t9xARrRWMD3w717NjgZ76SdWVc2kJ",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# Pièces jointes déposées pendant les tests (dossier ignoré par git)
config :social, storage_dir: Path.expand("../tmp/test_storage", __DIR__)

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]

# Notifications (MlShared.Notifications) : exécutées dans le processus appelant, un seul essai (faux centre des
# tests : MlSocialWeb.ConnCase.fake_accounts/1).
config :ml_shared, notifications_async: false, notifications_retry_delays: []
