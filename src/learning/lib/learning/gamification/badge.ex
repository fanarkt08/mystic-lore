defmodule MlLearning.Gamification.Badge do
  @moduledoc "Définition d'un badge : icône, rareté, critère et cible, contrôlés par la base."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "badges" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :icon, :string
    field :rarity, :string
    field :criterion, :string
    field :param, :string
    field :target, :integer
    field :position, :integer
    timestamps(type: :utc_datetime)
  end
end
