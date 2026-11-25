defmodule MlMultiplayer.Link do
  @moduledoc "Lien d'invitation temporaire et révocable ; seul le SHA-256 de son jeton est stocké."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "lobby_links" do
    field :lobby_id, :binary_id
    field :created_by, :binary_id
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :max_uses, :integer
    field :uses, :integer, default: 0
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def new_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  def hash(token), do: :crypto.hash(:sha256, token)

  def state(%__MODULE__{} = link, now \\ DateTime.utc_now()) do
    cond do
      link.revoked_at -> "revoked"
      DateTime.compare(link.expires_at, now) != :gt -> "expired"
      link.uses >= link.max_uses -> "exhausted"
      true -> "active"
    end
  end
end
