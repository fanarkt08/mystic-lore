defmodule MlAccounts.SanctionAppeal do
  @moduledoc "Appel motivé d'un membre contre une sanction : `open` → `accepted` (sanction levée) ou `rejected`."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sanction_appeals" do
    field :body, :string
    field :status, :string, default: "open"
    field :decided_by, Ecto.UUID
    field :decision_reason, :string
    field :decided_at, :utc_datetime
    belongs_to :sanction, MlAccounts.Sanction
    belongs_to :user, MlAccounts.User
    timestamps(type: :utc_datetime)
  end
end
