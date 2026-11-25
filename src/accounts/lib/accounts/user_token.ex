defmodule MlAccounts.UserToken do
  @moduledoc """
  Jeton envoyé par e-mail, à usage unique : seul son SHA-256 est stocké. `"reset_password"` vaut 1 heure,
  et seulement si l'adresse du compte est encore `sent_to` ; `"change_email"` confirme la nouvelle adresse (24 h).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_tokens" do
    field :context, :string
    field :token_hash, :binary, redact: true
    field :sent_to, :string
    belongs_to :user, MlAccounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
