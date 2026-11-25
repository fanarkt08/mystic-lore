defmodule MlSocial.Block do
  @moduledoc "Blocage de `blocked_id` par `blocker_id` (clé primaire sur la paire orientée)."
  use Ecto.Schema

  @primary_key false
  schema "blocks" do
    field :blocker_id, :binary_id, primary_key: true
    field :blocked_id, :binary_id, primary_key: true
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
