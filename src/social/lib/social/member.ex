defmodule MlSocial.Member do
  @moduledoc """
  Appartenance d'un membre à une conversation : date d'arrivée (ancienneté dans un groupe), dernière lecture et
  sourdine (`muted_until` : jusqu'à cette date ; « toujours » est stocké `forever/0`, le 31/12/9999).
  """
  use Ecto.Schema

  @forever ~U[9999-12-31 23:59:59.000000Z]

  @primary_key false
  schema "conversation_members" do
    field :conversation_id, :binary_id, primary_key: true
    field :user_id, :binary_id, primary_key: true
    field :joined_at, :utc_datetime_usec
    field :last_read_at, :utc_datetime_usec
    field :muted_until, :utc_datetime_usec
  end

  def forever, do: @forever

  @doc "Sourdine active à `now` ?"
  def muted?(%{muted_until: nil}, _now), do: false
  def muted?(%{muted_until: until}, now), do: DateTime.after?(until, now)

  @doc "Forme de l'API : `{muted, muted_until}`, avec `muted_until` à `nil` pour une sourdine sans fin."
  def mute_state(member, now \\ DateTime.utc_now()) do
    cond do
      not muted?(member, now) -> {false, nil}
      member.muted_until == @forever -> {true, nil}
      true -> {true, member.muted_until}
    end
  end
end
