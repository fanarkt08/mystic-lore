import Config

config :web, MysticWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "MBrP5Z7/njapNDjqcqKre0K5by2ww9/Z3KL+kw5eVkz7WQHA6OCnd8W3E3/WSeFo",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:web, ~w(--watch)]}
  ]

# Development only: link to accounts' dev mailbox after sign-up, demo accounts on the login page.
config :web, dev_hints: true

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

# secret interne de dev uniquement (INTERNAL_SECRET est obligatoire en prod)
config :ml_shared, internal_secret: "dev-internal-secret-not-for-production-0123456789abcdef"

# Limites relâchées en dev seulement, car les parcours e2e enchaînent des dizaines de connexions locales.
config :web, :rate_limits,
  login: {200, 60_000},
  register: {50, 60_000},
  confirmation: {50, 60_000},
  contact: {200, 3_600_000}
