defmodule MlStudio.Projects.Version do
  @moduledoc "Immutable snapshot of a project's content; restoring a version creates a new one."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  schema "versions" do
    field :number, :integer
    field :note, :string, default: ""
    field :source, :string
    field :author_id, Ecto.UUID
    field :snapshot, :map
    belongs_to :project, MlStudio.Projects.Project
    timestamps()
  end
end
