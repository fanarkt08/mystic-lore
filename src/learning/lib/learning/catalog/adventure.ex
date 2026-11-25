defmodule MlLearning.Catalog.Adventure do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "adventures" do
    field :slug, :string
    field :title, :string
    field :summary, :string
    field :description, :string, default: ""
    field :category, :string
    field :difficulty, :string
    field :premium, :boolean, default: false
    field :duration_minutes, :integer
    field :cover, :string
    field :objectives, {:array, :string}, default: []
    field :prerequisites, {:array, :string}, default: []
    # import studio (nil pour les aventures seedées)
    field :source, :string
    field :external_id, :binary_id
    field :imported_version, :integer
    field :author_id, :binary_id
    has_many :chapters, MlLearning.Catalog.Chapter
    timestamps(type: :utc_datetime)
  end
end
