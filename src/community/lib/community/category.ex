defmodule MlCommunity.Category do
  @moduledoc """
  Catégorie du forum, identifiée par son slug. Données de référence insérées par la migration (présentes dans
  tous les environnements) ; `staff_only` : seul le staff peut y ouvrir une discussion (Announcements).
  """
  use Ecto.Schema

  @primary_key {:slug, :string, autogenerate: false}
  schema "categories" do
    field :name, :string
    field :description, :string
    field :position, :integer
    field :staff_only, :boolean, default: false
  end
end
