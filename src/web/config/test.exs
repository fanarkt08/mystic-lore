import Config

config :web, MysticWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "w2FnFGhf5xaMdqh2f+bHQrNJCCanEyG543LYUU7C+mcJIBy+DlIpNd2zrnKsgYmy",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true

# secret interne de test uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "test-internal-secret-not-for-production-0123456789abcdef"
config :ml_shared, req_options: [plug: {Req.Test, MlShared.Client}, retry: false]
