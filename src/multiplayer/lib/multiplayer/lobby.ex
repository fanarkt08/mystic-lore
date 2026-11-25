defmodule MlMultiplayer.Lobby do
  @moduledoc "Salon d'une activité « The Rune Relay », ouvert ou privé, de 2 à 4 joueurs."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "lobbies" do
    field :host_id, :binary_id
    field :title, :string
    field :visibility, :string, default: "open"
    field :requires_approval, :boolean, default: false
    field :max_players, :integer, default: 4
    field :starts_at, :utc_datetime_usec
    field :status, :string, default: "waiting"
    field :current_match_id, :binary_id
    timestamps(type: :utc_datetime_usec)
  end

  @max_schedule_days 30

  @doc "Création : l'hôte et le statut sont posés par le serveur, jamais castés."
  def create_changeset(lobby, attrs, now \\ DateTime.utc_now()) do
    lobby
    |> cast(attrs, [:title, :visibility, :requires_approval, :max_players, :starts_at])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title, :visibility, :max_players])
    |> validate_length(:title, min: 3, max: 60, count: :codepoints)
    |> MlMultiplayer.Message.validate_no_nul(:title)
    |> validate_inclusion(:visibility, ~w(open private))
    |> validate_number(:max_players, greater_than_or_equal_to: 2, less_than_or_equal_to: 4)
    |> validate_change(:starts_at, fn :starts_at, at ->
      cond do
        DateTime.compare(at, now) != :gt ->
          [starts_at: "must be in the future"]

        DateTime.diff(at, now, :day) >= @max_schedule_days ->
          [starts_at: "must be within 30 days"]

        true ->
          []
      end
    end)
  end

  @doc "Vrai si l'activité est programmée plus tard que `now` (démarrage refusé avant)."
  def scheduled_later?(%__MODULE__{starts_at: nil}, _now), do: false
  def scheduled_later?(%__MODULE__{starts_at: at}, now), do: DateTime.compare(at, now) == :gt
end
