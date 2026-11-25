defmodule MlMultiplayer.Reward do
  @moduledoc """
  XP de victoire à livrer à learning pour un joueur : `pending` (en attente ou en reprise) → `awarded`,
  ou `failed` si learning refuse définitivement la demande (4xx). Une ligne au plus par (partie, joueur).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "match_rewards" do
    field :match_id, :binary_id
    field :user_id, :binary_id
    field :amount, :integer
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_error, :string
    field :awarded_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
