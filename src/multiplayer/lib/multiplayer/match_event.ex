defmodule MlMultiplayer.MatchEvent do
  @moduledoc """
  Événement du journal d'une partie. Ce journal contient le secret et n'est jamais renvoyé tel quel par l'API.
  """
  use Ecto.Schema

  @primary_key false
  schema "match_events" do
    field :match_id, :binary_id, primary_key: true
    field :seq, :integer, primary_key: true
    field :type, :string
    field :user_id, :binary_id
    field :payload, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def to_engine(%__MODULE__{type: type, user_id: user_id, payload: payload}),
    do: %{"type" => type, "user_id" => user_id, "payload" => payload}
end
