defmodule MlLearning.Gamification.UserBadge do
  @moduledoc "Badge gagné (unique par utilisateur). Équipé ⇔ `position` ∈ 1..3, unique par utilisateur (contraintes en base)."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_badges" do
    field :user_id, :binary_id
    field :earned_at, :utc_datetime
    field :equipped, :boolean, default: false
    field :position, :integer
    belongs_to :badge, MlLearning.Gamification.Badge
  end
end
