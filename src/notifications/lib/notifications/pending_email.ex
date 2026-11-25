defmodule MlNotifications.PendingEmail do
  @moduledoc "E-mail reporté pendant les heures calmes : il rejoindra le résumé envoyé à leur fin."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "pending_emails" do
    field :user_id, :binary_id
    field :notification_id, :binary_id
    field :category, :string
    field :kind, :string
    field :actor_id, :binary_id
    field :params, :map, default: %{}
    field :dedupe_key, :string
    field :mandatory, :boolean, default: false
    field :inserted_at, :utc_datetime_usec
  end
end
