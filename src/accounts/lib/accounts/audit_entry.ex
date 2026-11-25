defmodule MlAccounts.AuditEntry do
  @moduledoc """
  Entrée du journal d'audit central (ajout seul : un déclencheur en base refuse UPDATE et DELETE).
  `service` = service qui l'a écrite (jeton interne), `action` = `"<service>.<objet>.<verbe>"`.
  """
  use Ecto.Schema

  schema "audit_entries" do
    field :service, :string
    field :actor_id, Ecto.UUID
    field :action, :string
    field :target_type, :string
    field :target_id, :string
    field :reason, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
