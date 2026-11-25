# Configuration de compilation ; les variables d'environnement sont lues dans runtime.exs.
import Config

config :ml_shared, service_name: "accounts"

config :accounts,
  namespace: MlAccounts,
  ecto_repos: [MlAccounts.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :accounts, MlAccountsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlAccountsWeb.ErrorJSON], layout: false]

# Oban : exports de données, suppressions de compte à échéance et notifications.
config :accounts, Oban,
  repo: MlAccounts.Repo,
  # privacy : exports et suppressions ; notify : notifications de sécurité et du compte
  queues: [privacy: 3, notify: 3],
  # purge quotidienne des demandes de support (180 jours après la clôture par défaut)
  cron: [
    crontab: [
      {"*/5 * * * *", MlAccounts.Privacy.SweepWorker},
      {"23 3 * * *", MlAccounts.Support.PurgeWorker}
    ]
  ],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {30, :minutes}]

# Formulaire de contact : demandes par fenêtre glissante de 24 h, par compte et par adresse cible
# (la limite par IP est tenue par web).
config :accounts, :support_limits, account: {5, 24 * 60}, address: {3, 24 * 60}

# En dev, les e-mails restent en mémoire et se lisent sur /dev/mailbox.
config :accounts, MlAccounts.Mailer, adapter: Swoosh.Adapters.Local

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Jamais de mot de passe, de jeton, de code 2FA ni de challenge dans les journaux de requêtes, ni le texte
# ou l'adresse d'une demande de support.
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "code",
  "challenge",
  "message",
  "body",
  "internal_note",
  "email"
]

import_config "#{config_env()}.exs"
