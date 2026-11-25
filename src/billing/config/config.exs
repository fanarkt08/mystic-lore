import Config

config :ml_shared, service_name: "billing"

config :billing,
  namespace: MlBilling,
  ecto_repos: [MlBilling.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  # Used at runtime to refuse the local (DEMO) mode in production unless BILLING_LOCAL_MODE=true.
  env: config_env(),
  # DEMO plans and prices (amounts in cents, per month).
  plans: [
    %{
      key: "free",
      name: "Free",
      price_cents: 0,
      features: ["All free adventures", "XP, levels and streaks", "Friends and messages"]
    },
    %{
      key: "premium",
      name: "Premium",
      price_cents: 1200,
      features: ["Everything in Free", "All premium adventures"]
    },
    %{
      key: "vip",
      name: "VIP",
      price_cents: 2400,
      features: ["Everything in Premium", "Supports new adventure development"]
    }
  ],
  currency: "usd"

# Stripe is configured from the environment in runtime.exs; nothing is configured by default.
config :billing, :stripe, []

config :billing, Oban,
  repo: MlBilling.Repo,
  # default: period ends, Stripe cancellations; notify: notifications sent to the notification center
  queues: [default: 5, notify: 3],
  # Oban 2.24: top-level `cron:` = the former Oban.Plugins.Cron (renamed Oban.Cron).
  cron: [crontab: [{"*/15 * * * *", MlBilling.PeriodEndWorker}]],
  pruner: [max_age: {7, :days}]

config :billing, MlBillingWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MlBillingWeb.ErrorJSON], layout: false]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
