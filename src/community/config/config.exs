import Config

config :ml_shared, service_name: "community"

config :community,
  namespace: MlCommunity,
  ecto_repos: [MlCommunity.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# Pas de journalisation des requêtes SQL : leurs paramètres contiendraient le texte des publications.
config :community, MlCommunity.Repo, log: false

config :community, MlCommunityWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlCommunityWeb.ErrorJSON], layout: false]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Jamais de contenu publié, de détail de signalement ni de motif de modération dans les journaux de requêtes.
config :phoenix, :filter_parameters, ["password", "token", "title", "body", "details", "reason"]

import_config "#{config_env()}.exs"
