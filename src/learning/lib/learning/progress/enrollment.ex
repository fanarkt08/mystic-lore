defmodule MlLearning.Progress.Enrollment do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enrollments" do
    field :user_id, :binary_id
    field :completed_at, :utc_datetime
    belongs_to :adventure, MlLearning.Catalog.Adventure
    belongs_to :last_lesson, MlLearning.Catalog.Lesson
    timestamps(type: :utc_datetime)
  end
end
