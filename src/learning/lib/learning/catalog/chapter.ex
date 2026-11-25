defmodule MlLearning.Catalog.Chapter do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chapters" do
    field :position, :integer
    field :title, :string
    belongs_to :adventure, MlLearning.Catalog.Adventure
    has_many :lessons, MlLearning.Catalog.Lesson
    timestamps(type: :utc_datetime)
  end
end
