import Config

config :ml_shared, service_name: "notifications"

config :notifications,
  namespace: MlNotifications,
  ecto_repos: [MlNotifications.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  # Rétention : 90 jours après le dernier événement d'une notification, 500 notifications au plus par membre.
  retention_days: 90,
  max_per_member: 500,
  # E-mails : délai avant l'envoi d'une catégorie facultative (annulé si la notification est lue entre-temps),
  # un e-mail au plus par clé (ex. une conversation) et par heure, 20 par jour et par membre (hors sécurité).
  email_delay_seconds: 60,
  email_key_window_seconds: 3600,
  email_daily_cap: 20

# Heures calmes : fuseau IANA du membre, changements d'heure compris (DateTime + base `tz`).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Pas de journalisation des requêtes SQL : leurs paramètres contiendraient des titres et identifiants de membres.
config :notifications, MlNotifications.Repo, log: false

config :notifications, Oban,
  repo: MlNotifications.Repo,
  # email : envois unitaires et résumés de fin d'heures calmes (via accounts) ; maintenance : purge quotidienne
  queues: [email: 5, maintenance: 1],
  cron: [crontab: [{"17 3 * * *", MlNotifications.PurgeWorker}]],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {30, :minutes}]

config :notifications, MlNotificationsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlNotificationsWeb.ErrorJSON], layout: false]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Jamais de paramètres de notification (titres, noms de groupe) dans les journaux de requêtes.
config :phoenix, :filter_parameters, ["password", "token", "params", "title", "name"]

import_config "#{config_env()}.exs"
