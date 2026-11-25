defmodule MlCommunity.Vote do
  @moduledoc "Vote « utile » : clé primaire `(user_id, target_type, target_id)`, donc un seul par membre et par cible."
  use Ecto.Schema

  @primary_key false
  schema "votes" do
    field :user_id, :binary_id, primary_key: true
    field :target_type, :string, primary_key: true
    field :target_id, :binary_id, primary_key: true
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
