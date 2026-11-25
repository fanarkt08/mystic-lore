defmodule MlSocial.Conversation do
  @moduledoc """
  Conversation `direct` entre deux membres, unique par paire (`user_low` < `user_high`), ou `group` : un nom de
  1 à 60 caractères, un propriétaire (`owner_id`) et de 3 à 20 membres à la création (`MlSocial.Groups`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "conversations" do
    field :kind, :string, default: "direct"
    field :name, :string
    field :owner_id, :binary_id
    field :user_low, :binary_id
    field :user_high, :binary_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def group?(%__MODULE__{kind: kind}), do: kind == "group"

  @doc "L'autre participant d'une conversation directe, vu par `me` (`nil` pour un groupe)."
  def other(%__MODULE__{kind: "group"}, _me), do: nil
  def other(%__MODULE__{user_low: me, user_high: other}, me), do: other
  def other(%__MODULE__{user_low: other}, _me), do: other
end
