defmodule MlLearning.Catalog.Lesson do
  @moduledoc """
  Leçon d'une aventure. `content` est public ; `solution` reste toujours côté serveur.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "lessons" do
    field :position, :integer
    field :title, :string
    field :kind, :string
    field :body, :string, default: ""
    field :content, :map, default: %{}
    field :solution, :map, default: %{}, redact: true
    field :xp_reward, :integer
    field :revision, :integer, default: 1, read_after_writes: true
    field :revised_at, :utc_datetime, read_after_writes: true
    belongs_to :chapter, MlLearning.Catalog.Chapter
    timestamps(type: :utc_datetime)
  end
end
