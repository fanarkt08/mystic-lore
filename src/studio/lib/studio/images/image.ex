defmodule MlStudio.Images.Image do
  @moduledoc "An illustration of a project, uploaded or drawn by the demo generator."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "images" do
    field :uploader_id, Ecto.UUID
    field :alt, :string, default: ""
    field :content_type, :string
    field :byte_size, :integer
    field :source, :string
    belongs_to :project, MlStudio.Projects.Project
    belongs_to :lesson, MlStudio.Projects.Lesson
    timestamps()
  end
end
