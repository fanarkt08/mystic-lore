defmodule MlBilling.Invoice do
  @moduledoc "An invoice reported by the provider (`paid` | `failed`). Amounts in cents."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  schema "invoices" do
    field :user_id, Ecto.UUID
    field :provider, :string
    field :provider_invoice_id, :string
    field :provider_subscription_id, :string
    field :amount_cents, :integer
    field :currency, :string
    field :status, :string
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :hosted_url, :string
    timestamps()
  end
end
