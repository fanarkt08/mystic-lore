import Config

config :ml_shared, service_name: "social"

config :social,
  namespace: MlSocial,
  ecto_repos: [MlSocial.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# Pas de journalisation des requêtes SQL : leurs paramètres contiendraient le texte des messages.
config :social, MlSocial.Repo, log: false

config :social, MlSocialWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlSocialWeb.ErrorJSON], layout: false]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Jamais de contenu de message, de pièce jointe ni de détail de signalement dans les journaux de requêtes.
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "body",
  "details",
  "data_base64",
  "alt",
  "filename",
  "name",
  "reason"
]

import_config "#{config_env()}.exs"
