defmodule MlStudio.Media.Medium do
  @moduledoc "A medium of a video lesson: the video or a caption track."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "media" do
    field :uploader_id, Ecto.UUID
    field :kind, :string
    field :content_type, :string
    field :byte_size, :integer
    field :lang, :string
    field :label, :string
    belongs_to :project, MlStudio.Projects.Project
    timestamps()
  end
end
