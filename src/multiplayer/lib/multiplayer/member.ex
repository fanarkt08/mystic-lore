defmodule MlMultiplayer.Member do
  @moduledoc "Relation d'un membre avec un salon ; `last_seen_at` est la source de vérité de sa connexion."
  use Ecto.Schema

  @primary_key false
  schema "lobby_members" do
    field :lobby_id, :binary_id, primary_key: true
    field :user_id, :binary_id, primary_key: true
    field :status, :string
    field :ready, :boolean, default: false
    field :connection, :string, default: "online"
    field :last_seen_at, :utc_datetime_usec
    field :joined_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
