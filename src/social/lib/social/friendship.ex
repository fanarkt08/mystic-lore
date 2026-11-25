defmodule MlSocial.Friendship do
  @moduledoc """
  Demande d'ami (`pending`) ou amitié (`accepted`) entre `requester_id` et `addressee_id`.
  Une seule ligne par paire non ordonnée (index unique `friendships_pair_index`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "friendships" do
    field :requester_id, :binary_id
    field :addressee_id, :binary_id
    field :status, :string, default: "pending"
    timestamps(type: :utc_datetime_usec)
  end
end
