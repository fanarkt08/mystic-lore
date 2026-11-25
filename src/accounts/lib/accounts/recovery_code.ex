defmodule MlAccounts.RecoveryCode do
  @moduledoc "Code de récupération 2FA à usage unique (supprimé à l'emploi) : seul un SHA-256 est stocké."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "recovery_codes" do
    field :code_hash, :binary, redact: true
    belongs_to :user, MlAccounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
