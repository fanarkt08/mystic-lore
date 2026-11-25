import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :learning, MlLearning.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "ml_learning_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :learning, MlLearningWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Njattk3wp7Z1ocGazT2RVz47lWA+eToOjWnw64tTFBXsxtaptoU74H3vLzBgK1iS",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]

# Notifications (MlShared.Notifications) : exécutées dans le processus appelant, un seul essai.
config :ml_shared, notifications_async: false, notifications_retry_delays: []
