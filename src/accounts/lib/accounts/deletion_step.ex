defmodule MlAccounts.DeletionStep do
  @moduledoc "Étape réussie de l'exécution d'une suppression de compte (une par service, `accounts` en dernier)."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "deletion_steps" do
    belongs_to :user, MlAccounts.User, primary_key: true
    field :service, :string, primary_key: true
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
