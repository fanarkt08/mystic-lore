defmodule MlAccounts.LoginChallenge do
  @moduledoc """
  Second facteur à la connexion : émis après un mot de passe correct quand la 2FA est active.
  Jeton opaque (SHA-256 stocké), valable 5 minutes, 5 essais (`attempts` réservé avant chaque vérification).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "login_challenges" do
    field :token_hash, :binary, redact: true
    field :attempts, :integer, default: 0
    belongs_to :user, MlAccounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
