import Config

config :web, MysticWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# HTTPS only (HSTS included); /healthz stays reachable over plain HTTP for local probes.
config :web, MysticWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [paths: ["/healthz"], hosts: ["localhost", "127.0.0.1"]]
  ]

# Session cookie flagged `secure` (compile-time, read by the endpoint).
config :web, secure_cookies: true

config :logger, level: :info
