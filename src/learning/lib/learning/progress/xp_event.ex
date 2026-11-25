defmodule MlLearning.Progress.XpEvent do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "xp_events" do
    field :user_id, :binary_id
    field :ref_key, :string
    field :amount, :integer
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
