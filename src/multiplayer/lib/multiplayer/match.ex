defmodule MlMultiplayer.Match do
  @moduledoc """
  Partie de « The Rune Relay ». `last_seq` = dernier numéro écrit dans `match_events` : toute écriture
  vérifie, sous verrou de la ligne, qu'elle prolonge exactement ce journal.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "matches" do
    field :lobby_id, :binary_id
    field :status, :string, default: "active"
    field :last_seq, :integer, default: 0
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
