defmodule MlMultiplayer.Invite do
  @moduledoc "Invitation d'un ami dans un salon : `pending` → `accepted` | `declined` | `revoked` (une par invité et par salon)."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "lobby_invites" do
    field :lobby_id, :binary_id
    field :inviter_id, :binary_id
    field :invitee_id, :binary_id
    field :status, :string, default: "pending"
    timestamps(type: :utc_datetime_usec)
  end
end
