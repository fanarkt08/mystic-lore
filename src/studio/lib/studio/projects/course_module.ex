defmodule MlStudio.Projects.CourseModule do
  @moduledoc "A module of a project (a chapter once published), ordered by `position`."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "modules" do
    field :position, :integer
    field :title, :string
    field :lock_version, :integer, default: 1
    belongs_to :project, MlStudio.Projects.Project

    has_many :lessons, MlStudio.Projects.Lesson,
      foreign_key: :module_id,
      preload_order: [asc: :position]

    timestamps()
  end

  def changeset(module, attrs) do
    module
    |> cast(attrs, [:title])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 200)
  end
end
