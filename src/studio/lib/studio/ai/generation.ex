defmodule MlStudio.AI.Generation do
  @moduledoc "An AI generation and the state of its billing reservation, settled exactly once."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "generations" do
    field :user_id, Ecto.UUID
    field :kind, :string
    field :status, :string, default: "pending"
    field :cost, :integer
    field :provider, :string
    field :model, :string
    field :brief, :string
    field :result, :map
    field :error, :string
    field :credits, :string, default: "reserved"
    field :retry_of, Ecto.UUID
    field :applied_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    belongs_to :project, MlStudio.Projects.Project
    belongs_to :lesson, MlStudio.Projects.Lesson
    timestamps()
  end

  def kinds, do: ~w(outline lesson_draft feedback image)
  def ref(%__MODULE__{id: id}), do: "studio:gen:" <> id
end
