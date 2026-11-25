defmodule MlStudio.Projects.Collaborator do
  @moduledoc """
  A member invited by the owner (by username): `editor` (edits and runs AI generations) or
  `viewer` (read only). The username is kept for display (it never changes in accounts).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "collaborators" do
    field :user_id, Ecto.UUID
    field :username, :string
    field :role, :string
    field :invited_by, Ecto.UUID
    belongs_to :project, MlStudio.Projects.Project
    timestamps()
  end

  def roles, do: ~w(editor viewer)
end
