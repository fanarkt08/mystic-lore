defmodule MlAccounts.Preferences do
  @moduledoc """
  Valide les préférences d'un membre : langue, fuseau, thème, accessibilité et objectif quotidien.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @themes ~w(system light dark)
  @vip_themes ~w(grove ember parchment)
  @fields ~w(language time_zone theme reduce_motion high_contrast text_size underline_links captions daily_xp_goal)a

  def vip_themes, do: @vip_themes

  @primary_key false
  embedded_schema do
    field :language, :string, default: "auto"
    field :time_zone, :string, default: "auto"
    field :theme, :string, default: "system"
    field :reduce_motion, :boolean, default: false
    field :high_contrast, :boolean, default: false
    field :text_size, :integer, default: 100
    field :underline_links, :boolean, default: false
    field :captions, :boolean, default: true
    field :daily_xp_goal, :integer, default: 20
  end

  @doc "Changements partiels : les champs absents gardent leur valeur ; aucun ne peut devenir nul."
  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:language, ~w(auto en fr))
    |> validate_inclusion(:theme, @themes ++ @vip_themes)
    |> validate_inclusion(:text_size, [100, 112, 125, 150])
    |> validate_inclusion(:daily_xp_goal, [10, 20, 50, 100])
    |> validate_change(:time_zone, fn :time_zone, zone ->
      if zone == "auto" or time_zone?(zone), do: [], else: [time_zone: "is not a known time zone"]
    end)
  end

  @doc "Nom IANA connu de la base embarquée (`Etc/UTC` compris)."
  def time_zone?(zone) when is_binary(zone) and byte_size(zone) <= 64,
    do: match?({:ok, _}, DateTime.now(zone, Tz.TimeZoneDatabase))

  def time_zone?(_zone), do: false

  @doc "Forme JSON du contrat."
  def to_map(%__MODULE__{} = prefs), do: Map.take(prefs, @fields)
end
