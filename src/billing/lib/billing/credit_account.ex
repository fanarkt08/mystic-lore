defmodule MlBilling.CreditAccount do
  @moduledoc "AI credit account of a user, locked by every credit operation; `balance` can never go below 0."
  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "credit_accounts" do
    field :period, :string
    field :plan, :string
    field :allocation, :integer, default: 0
    field :balance, :integer, default: 0
    field :reserved, :integer, default: 0
    timestamps()
  end
end
