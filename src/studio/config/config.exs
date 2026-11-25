import Config

config :ml_shared, service_name: "studio"

config :studio,
  namespace: MlStudio,
  ecto_repos: [MlStudio.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  # Used at runtime: the DEMO provider is never chosen implicitly in production.
  env: config_env(),
  # Credits charged per AI generation (billing ledger); images are reserved to the VIP plan.
  ai_costs: %{"outline" => 2, "lesson_draft" => 5, "feedback" => 2, "image" => 12}

# Real provider (MlStudio.AI.Anthropic): only used when chosen, see runtime.exs.
config :studio, :anthropic,
  model: "claude-fable-5-2",
  effort: "high",
  max_tokens: 16_000,
  receive_timeout: 300_000

config :studio, Oban,
  repo: MlStudio.Repo,
  # ai: provider calls; credits: settlement of reservations; publish: imports into learning;
  # notify: review decisions sent to the notification center
  queues: [ai: 3, credits: 5, publish: 2, notify: 3],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {30, :minutes}]

config :studio, MlStudioWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlStudioWeb.ErrorJSON], layout: false]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
