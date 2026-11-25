defmodule MlBilling.WebhookEvent do
  @moduledoc "Journal of received provider events, unique by `(provider, provider_event_id)`."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "webhook_events" do
    field :provider, :string
    field :provider_event_id, :string
    field :type, :string
    field :event_created_at, :utc_datetime
    field :user_id, Ecto.UUID
    field :status, :string
    field :error, :string
    field :payload, :map
    timestamps()
  end
end
