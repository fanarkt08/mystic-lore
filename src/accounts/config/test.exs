import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :accounts, MlAccounts.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "ml_accounts_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :accounts, MlAccountsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "q5ppIH90PqD8P/HEohEcdDMLF1Vz1vnxfAD7DwuSC4PoiknKOIce3Ai9g9nBmTgN",
  server: false

# Tâches insérées mais exécutées seulement à la demande (Oban.Testing.perform_job/3) ; pas de cron.
config :accounts, Oban, testing: :manual

# Avatars téléversés pendant les tests (dossier ignoré par git)
config :accounts, storage_dir: Path.expand("../tmp/test_storage", __DIR__)

# In test we don't send emails
config :accounts, MlAccounts.Mailer, adapter: Swoosh.Adapters.Test

# Hachage bcrypt minimal en test (rapidité) ; coût par défaut (12) ailleurs.
config :bcrypt_elixir, :log_rounds, 4

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]
