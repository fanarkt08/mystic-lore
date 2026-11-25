import Config

config :billing, MlBilling.Repo,
  username: System.get_env("DB_USER") || System.get_env("USER", "postgres"),
  password: System.get_env("DB_PASSWORD", ""),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "ml_billing_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :billing, MlBillingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4103],
  secret_key_base: "TPZ5sLTho4aKJv1KdHzdJ4Qx1Mp2jrfF6uRuByFv27ADeZA7DXM98CbzLB16Okia",
  server: false

# Jobs are inserted but only run explicitly (Oban.Testing.perform_job/2); cron is off.
config :billing, Oban, testing: :manual

# Stripe client requests go to Req.Test stubs named MlBilling.Stripe (no network).
config :billing, :stripe_req_options, plug: {Req.Test, MlBilling.Stripe}, retry: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]
