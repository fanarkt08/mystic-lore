defmodule MlSocial.Report do
  @moduledoc """
  Signalement d'un membre ou d'un message. Pour un message, `message_body`, `message_sender_id` et
  `message_sent_at` sont un instantané pris au moment du signalement.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "reports" do
    field :reporter_id, :binary_id
    field :target_type, :string
    # Ecto.UUID (et non :binary_id) : le cast doit refuser une valeur qui n'est pas un UUID.
    field :target_id, Ecto.UUID
    field :reason, :string
    field :details, :string
    field :message_body, :string
    field :message_sender_id, :binary_id
    field :message_sent_at, :utc_datetime_usec
    field :message_attachment_id, :binary_id
    # traitement par le staff (MlSocial.Moderation)
    field :status, :string, default: "open"
    field :resolution, :string
    field :resolution_reason, :string
    field :resolved_by, :binary_id
    field :resolved_at, :utc_datetime_usec
    field :sanction_id, :binary_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:target_type, :target_id, :reason, :details])
    |> validate_required([:target_type, :target_id, :reason])
    |> validate_inclusion(:target_type, ~w(user message))
    |> validate_inclusion(:reason, ~w(harassment spam inappropriate other))
    |> update_change(:details, &String.trim/1)
    |> validate_length(:details, max: 2000, count: :codepoints)
    |> MlSocial.Message.validate_no_nul(:details)
  end
end
