defmodule MlLearning.Progress.LessonProgress do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "lesson_progress" do
    field :user_id, :binary_id
    field :status, :string, default: "in_progress"
    field :attempts, :integer, default: 0
    field :notes, :string
    field :draft, :string
    field :notes_saved_at, :utc_datetime
    field :completed_at, :utc_datetime
    belongs_to :lesson, MlLearning.Catalog.Lesson
    timestamps(type: :utc_datetime)
  end
end
