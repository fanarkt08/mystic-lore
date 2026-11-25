import Config

config :ml_shared, service_name: "multiplayer"

config :multiplayer,
  namespace: MlMultiplayer,
  ecto_repos: [MlMultiplayer.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# Pas de journalisation des requêtes SQL : leurs paramètres contiendraient le chat, les indices et le secret.
config :multiplayer, MlMultiplayer.Repo, log: false

# Règles du jeu et de la présence (surchargées en test).
config :multiplayer, :rules,
  # battement attendu toutes les ~10 s : « déconnecté » après 30 s sans battement, « absent » 60 s plus tard
  disconnect_after: 30,
  absent_after: 90,
  # partie interrompue si tous ses joueurs sont absents depuis 10 minutes
  abandon_after: 600,
  # balayage des connexions et des récompenses en attente (ms) ; `false` le désactive
  sweep_interval: 5_000

config :multiplayer, MlMultiplayerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlMultiplayerWeb.ErrorJSON], layout: false]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Jamais de message de chat, de jeton de lien ni de séquence proposée dans les journaux de requêtes.
config :phoenix, :filter_parameters, ["password", "token", "body", "details", "sequence"]

import_config "#{config_env()}.exs"
