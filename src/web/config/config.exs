import Config

config :ml_shared, service_name: "web"

config :web, namespace: Mystic

# Public URL of this service (used for checkout return URLs). Overridden by WEB_URL at runtime.
config :web, web_url: "http://localhost:4000"

# Simple in-memory rate limits (per client IP): {max requests, window in ms}.
config :web, :rate_limits,
  login: {10, 60_000},
  register: {5, 60_000},
  confirmation: {5, 60_000},
  contact: {10, 3_600_000}

config :web, MysticWeb.Gettext, default_locale: "en", locales: ~w(en fr)

# Dates et heures converties dans le fuseau du membre (`MysticWeb.Format`) : base embarquée, sans mise à jour réseau.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :web, MysticWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MysticWeb.ErrorHTML, json: MysticWeb.ErrorJSON],
    layout: false
  ],
  # The cluster-wide PubSub of ml_shared (domain events + LiveView socket disconnects).
  pubsub_server: MlShared.PubSub,
  live_view: [signing_salt: "7qH9z2Af"]

config :esbuild,
  version: "0.25.4",
  web: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.3",
  web: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Jamais de secrets ni de contenus publiés/privés dans les journaux (paramètres HTTP et événements LiveView).
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "one_time_password",
  "code",
  "body",
  "title",
  "details",
  "reason",
  "message",
  # adresse saisie dans le formulaire de contact, note interne du support
  "email",
  "internal_note"
]

import_config "#{config_env()}.exs"
