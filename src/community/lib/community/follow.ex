defmodule MlCommunity.Follow do
  @moduledoc "Suivi d'une discussion par un membre (clé primaire sur la paire) : notifié de chaque nouvelle réponse."
  use Ecto.Schema

  @primary_key false
  schema "follows" do
    field :user_id, :binary_id, primary_key: true
    field :discussion_id, :binary_id, primary_key: true
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
