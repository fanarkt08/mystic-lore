defmodule MlAccounts.DataExport do
  @moduledoc """
  Export des données d'un membre : `pending` pendant l'assemblage, puis `ready` (téléchargeable jusqu'à
  `expires_at`) ou `failed` (services en cause dans `failed_services`). Supprimé une fois expiré.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "data_exports" do
    field :status, :string, default: "pending"
    # sections par service ("accounts", "learning"…) ; partielles tant que l'export est en cours
    field :data, :map, redact: true
    field :failed_services, {:array, :string}, default: []
    field :completed_at, :utc_datetime
    field :expires_at, :utc_datetime
    belongs_to :user, MlAccounts.User
    timestamps(type: :utc_datetime)
  end
end
