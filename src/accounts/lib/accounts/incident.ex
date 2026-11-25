defmodule MlAccounts.Incident do
  @moduledoc "Incident suivi par le staff : `open` → `investigating` → `resolved` (résumé obligatoire), avec sa chronologie."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "incidents" do
    field :title, :string
    field :severity, :string
    field :status, :string, default: "open"
    field :summary, :string
    field :created_by, Ecto.UUID
    field :resolved_by, Ecto.UUID
    field :resolved_at, :utc_datetime
    has_many :updates, MlAccounts.IncidentUpdate, preload_order: [asc: :inserted_at]
    timestamps(type: :utc_datetime)
  end

  def severities, do: ~w(low medium high critical)
  def statuses, do: ~w(open investigating resolved)
end

defmodule MlAccounts.IncidentUpdate do
  @moduledoc "Mise à jour de la chronologie d'un incident (`status` / `severity` : valeurs posées par cette mise à jour)."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "incident_updates" do
    field :author_id, Ecto.UUID
    field :body, :string
    field :status, :string
    field :severity, :string
    belongs_to :incident, MlAccounts.Incident
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
