defmodule MlAccounts.Sanction do
  @moduledoc "Sanction d'un membre ; elle n'est jamais supprimée, seulement levée."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sanctions" do
    field :kind, :string
    field :reason, :string
    field :issued_by, Ecto.UUID
    field :ends_at, :utc_datetime
    field :ref, :string
    field :lifted_at, :utc_datetime
    field :lifted_by, Ecto.UUID
    field :lift_reason, :string
    belongs_to :user, MlAccounts.User
    has_many :appeals, MlAccounts.SanctionAppeal, preload_order: [desc: :inserted_at]
    timestamps(type: :utc_datetime)
  end

  @doc "`active`, `expired` (restriction échue) ou `lifted`."
  def status(%__MODULE__{} = s, now \\ DateTime.utc_now()) do
    cond do
      s.lifted_at -> "lifted"
      s.kind == "restriction" and DateTime.compare(s.ends_at, now) != :gt -> "expired"
      true -> "active"
    end
  end
end
