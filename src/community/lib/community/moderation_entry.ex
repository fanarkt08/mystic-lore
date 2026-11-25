defmodule MlCommunity.ModerationEntry do
  @moduledoc """
  Journal de modération (table `moderation_log`, en ajout seul) : membre du staff, action, cible, motif et
  détails (`from` / `to`, signalement résolu…). Écrit dans la même transaction que l'action elle-même.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "moderation_log" do
    field :moderator_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :reason, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
