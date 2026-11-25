defmodule MlNotifications.Notification do
  @moduledoc "Une notification d'un destinataire, au plus une non lue par clé."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "notifications" do
    field :user_id, :binary_id
    field :category, :string
    field :kind, :string
    field :actor_id, :binary_id
    field :subject_type, :string
    field :subject_id, :string
    field :params, :map, default: %{}
    field :dedupe_key, :string
    field :count, :integer, default: 1
    field :read_at, :utc_datetime_usec
    field :last_event_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Forme du contrat (clés chaînes) ; `actor` : identité d'accounts (`nil` si inconnue ou injoignable)."
  def to_map(%__MODULE__{} = n, actors \\ %{}) do
    %{
      "id" => n.id,
      "category" => n.category,
      "kind" => n.kind,
      "actor_id" => n.actor_id,
      "actor" => n.actor_id && Map.get(actors, n.actor_id),
      "subject" => n.subject_type && %{"type" => n.subject_type, "id" => n.subject_id},
      "params" => n.params,
      "count" => n.count,
      "read" => not is_nil(n.read_at),
      "read_at" => n.read_at,
      "created_at" => n.inserted_at,
      "updated_at" => n.last_event_at
    }
  end
end
