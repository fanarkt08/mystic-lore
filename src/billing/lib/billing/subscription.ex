defmodule MlBilling.Subscription do
  @moduledoc """
  The user's subscription (one row per user). Written only by the webhook pipeline
  (`MlBilling.Webhooks`), plus the cancel flag echoed by Stripe's API on cancel/resume.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  schema "subscriptions" do
    field :user_id, Ecto.UUID
    field :plan, :string, default: "free"
    field :status, :string, default: "none"
    field :provider, :string
    field :provider_customer_id, :string
    field :provider_subscription_id, :string
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :cancel_at_period_end, :boolean, default: false
    field :past_due_since, :utc_datetime
    field :last_event_at, :utc_datetime
    timestamps()
  end
end
