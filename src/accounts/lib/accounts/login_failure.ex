defmodule MlAccounts.LoginFailure do
  @moduledoc "Tentative de connexion échouée, par e-mail normalisé (verrouillage en base, partagé entre nœuds)."
  use Ecto.Schema

  schema "login_failures" do
    field :email, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
