defmodule MlSocial.Setting do
  @moduledoc "Réglages de confidentialité d'un membre ; une ligne absente vaut les valeurs par défaut."
  use Ecto.Schema
  import Ecto.Changeset

  @fields [:show_online, :read_receipts, :friend_requests, :group_adds, :lobby_invites]

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "settings" do
    field :show_online, :boolean, default: true
    field :read_receipts, :boolean, default: true
    field :friend_requests, :string, default: "everyone"
    field :group_adds, :string, default: "friends"
    field :lobby_invites, :string, default: "friends"
    timestamps(type: :utc_datetime_usec, inserted_at: false)
  end

  @doc "Changement partiel ; aucune valeur ne peut devenir nulle."
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields)
    |> validate_inclusion(:friend_requests, ~w(everyone friends_of_friends nobody))
    |> validate_inclusion(:group_adds, ~w(friends nobody))
    |> validate_inclusion(:lobby_invites, ~w(friends nobody))
  end

  def to_map(%__MODULE__{} = s), do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(s, &1)})
end
