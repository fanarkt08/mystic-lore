defmodule MlBilling.Repo.Migrations.CreateBilling do
  use Ecto.Migration

  def change do
    # One row per user (users live in the accounts database: no foreign key).
    # status "none" = row created by an event before any activation (row lock target).
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :plan, :string, null: false, default: "free"
      add :status, :string, null: false, default: "none"
      add :provider, :string, null: false
      add :provider_customer_id, :string
      add :provider_subscription_id, :string
      add :current_period_start, :utc_datetime
      add :current_period_end, :utc_datetime
      add :cancel_at_period_end, :boolean, null: false, default: false
      # start of the 3-day grace period of a past_due subscription
      add :past_due_since, :utc_datetime
      # `created` of the newest provider event applied (older events are ignored)
      add :last_event_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscriptions, [:user_id])
    create unique_index(:subscriptions, [:provider, :provider_subscription_id])
    create index(:subscriptions, [:provider, :provider_customer_id])

    create constraint(:subscriptions, :subscriptions_plan,
             check: "plan IN ('free','premium','vip')"
           )

    create constraint(:subscriptions, :subscriptions_status,
             check: "status IN ('none','active','past_due','canceled')"
           )

    create constraint(:subscriptions, :subscriptions_provider,
             check: "provider IN ('local','stripe')"
           )

    create table(:invoices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :provider, :string, null: false
      add :provider_invoice_id, :string, null: false
      add :provider_subscription_id, :string
      add :amount_cents, :integer, null: false
      add :currency, :string, null: false
      add :status, :string, null: false
      add :period_start, :utc_datetime
      add :period_end, :utc_datetime
      add :hosted_url, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoices, [:provider, :provider_invoice_id])
    create index(:invoices, [:user_id, :inserted_at])
    create constraint(:invoices, :invoices_amount, check: "amount_cents >= 0")
    create constraint(:invoices, :invoices_status, check: "status IN ('paid','failed')")

    # Deduplication: (provider, provider_event_id) is unique, inserts use ON CONFLICT DO NOTHING.
    create table(:webhook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :provider_event_id, :string, null: false
      add :type, :string, null: false
      add :event_created_at, :utc_datetime, null: false
      add :user_id, :binary_id
      add :status, :string, null: false
      add :error, :string
      add :payload, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:webhook_events, [:provider, :provider_event_id])

    create constraint(:webhook_events, :webhook_events_status,
             check: "status IN ('received','processed','ignored','stale','failed')"
           )

    # Checkout sessions (local DEMO and Stripe). No card data is ever stored.
    create table(:checkout_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :plan, :string, null: false
      add :status, :string, null: false, default: "open"
      add :provider, :string, null: false
      add :provider_session_id, :string, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:checkout_sessions, [:provider, :provider_session_id])
    create index(:checkout_sessions, [:user_id])
    create constraint(:checkout_sessions, :checkout_plan, check: "plan IN ('premium','vip')")

    create constraint(:checkout_sessions, :checkout_status,
             check: "status IN ('open','completed')"
           )
  end
end
