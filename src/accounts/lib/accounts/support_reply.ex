defmodule MlAccounts.SupportReply do
  @moduledoc """
  Réponse du staff à une demande de support, envoyée par e-mail par accounts. `email_status` : `sent` (remise au
  Mailer réussie) ou `failed` (la réponse est gardée, l'interface du staff le dit : jamais un faux « envoyé »).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "support_replies" do
    field :author_id, Ecto.UUID
    field :body, :string
    field :email_status, :string
    belongs_to :request, MlAccounts.SupportRequest
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
