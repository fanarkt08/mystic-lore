defmodule MlLearning.Offline.Action do
  @moduledoc """
  Reçu d'une action rejouée depuis la file hors ligne, unique par `(user_id, key)`. Il garde la réponse rendue
  la première fois et une empreinte de la demande (`request_hash`), jamais la réponse envoyée elle-même.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "idempotent_actions" do
    field :user_id, :binary_id
    field :key, :binary_id
    field :action, :string
    field :request_hash, :string
    field :response, :map, default: %{}
    belongs_to :lesson, MlLearning.Catalog.Lesson
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
