defmodule MlBilling.CreditEntry do
  @moduledoc "A line of the append-only AI credit ledger; an operation is never applied twice."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @kinds ~w(allocation top_up reservation consumption release expiration adjustment)
  def kinds, do: @kinds

  schema "credit_entries" do
    # total order of the ledger (bigserial): history is sorted by it
    field :seq, :integer, read_after_writes: true
    field :user_id, Ecto.UUID
    field :kind, :string
    field :amount, :integer
    field :delta, :integer
    field :balance_after, :integer
    field :ref, :string
    field :reason, :string
    field :period, :string
    timestamps()
  end
end
