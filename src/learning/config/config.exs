import Config

config :ml_shared, service_name: "learning"

config :learning,
  namespace: MlLearning,
  ecto_repos: [MlLearning.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :learning, MlLearningWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlLearningWeb.ErrorJSON], layout: false]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Réponses, notes et brouillons des apprenants ne doivent jamais apparaître dans les journaux.
config :phoenix, :filter_parameters, ["password", "secret", "token", "answer", "notes", "draft"]

import_config "#{config_env()}.exs"
