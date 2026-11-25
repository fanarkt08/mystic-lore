defmodule MlNotifications.Setting do
  @moduledoc """
  Préférences d'un membre : `channels` (seulement ses choix, `%{catégorie => %{canal => booléen}}`) et heures
  calmes (`quiet_enabled`, `quiet_start`, `quiet_end`), en heures locales du fuseau `time_zone`.
  """
  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "notification_settings" do
    field :channels, :map, default: %{}
    field :quiet_enabled, :boolean, default: false
    field :quiet_start, :time, default: ~T[22:00:00]
    field :quiet_end, :time, default: ~T[07:00:00]
    field :time_zone, :string
    timestamps(type: :utc_datetime_usec)
  end
end
