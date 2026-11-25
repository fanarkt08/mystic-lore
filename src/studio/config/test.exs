import Config

config :studio, MlStudio.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "ml_studio_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :studio, MlStudioWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4107],
  secret_key_base: "UyDJQDtMBn/4zaxavSnvcCgllSbPRLw6dqGCqQYzNIq3H7K4y9FPs4I1LKjX0zPd",
  server: false

# Jobs are inserted but only run explicitly (Oban.Testing.perform_job/2).
config :studio, Oban, testing: :manual

# Tests choose the AI provider explicitly instead of inheriting the developer's shell.
config :studio, ai_provider: "demo", storage_dir: Path.expand("../tmp/test_storage", __DIR__)

# Anthropic requests go to Req.Test stubs named MlStudio.AI.Anthropic (no network).
config :studio, :anthropic_req_options, plug: {Req.Test, MlStudio.AI.Anthropic}, retry: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]
