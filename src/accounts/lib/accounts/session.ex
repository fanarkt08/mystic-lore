defmodule MlAccounts.Session do
  @moduledoc "Session opaque dont seul le SHA-256 du jeton est stocké, avec une expiration glissante."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sessions" do
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime
    field :user_agent, :string
    field :ip, :string
    belongs_to :user, MlAccounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
