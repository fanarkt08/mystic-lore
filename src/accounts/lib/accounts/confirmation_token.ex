defmodule MlAccounts.ConfirmationToken do
  @moduledoc "Jeton de confirmation d'e-mail à usage unique : seul son SHA-256 est stocké."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "confirmation_tokens" do
    field :token_hash, :binary, redact: true
    belongs_to :user, MlAccounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
