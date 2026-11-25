defmodule MlCommunity.Report do
  @moduledoc """
  Signalement d'une discussion ou d'une réponse, avec un instantané du contenu pris au moment du signalement.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @reasons ~w(harassment spam inappropriate other)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "reports" do
    field :reporter_id, :binary_id
    field :target_type, :string
    # Ecto.UUID (et non :binary_id) : le cast doit refuser une valeur qui n'est pas un UUID.
    field :target_id, Ecto.UUID
    field :reason, :string
    field :details, :string
    field :snapshot, :map
    field :status, :string, default: "open"
    field :resolution, :string
    field :resolution_reason, :string
    field :resolved_by, :binary_id
    field :resolved_at, :utc_datetime_usec
    field :target_status, :string, virtual: true
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:target_type, :target_id, :reason, :details])
    |> validate_required([:target_type, :target_id, :reason])
    |> validate_inclusion(:target_type, ~w(discussion reply))
    |> validate_inclusion(:reason, @reasons)
    |> update_change(:details, &String.trim/1)
    |> validate_length(:details, max: 2000)
    |> MlCommunity.validate_no_nul([:details])
    |> unique_constraint(:target_id, name: :reports_one_open_index)
  end
end
