defmodule MlLearning.Gamification.Quest do
  @moduledoc "Quête quotidienne : `kind` ∈ `lessons_completed|xp_earned|note_written`, `target` ≥ 1, `xp_reward` 1..500."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "quests" do
    field :slug, :string
    field :title, :string
    field :description, :string
    field :kind, :string
    field :target, :integer
    field :xp_reward, :integer
    field :position, :integer
    timestamps(type: :utc_datetime)
  end
end
