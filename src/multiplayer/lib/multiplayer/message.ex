defmodule MlMultiplayer.Message do
  @moduledoc "Message du chat d'un salon : 1 à 500 caractères après suppression des espaces de bord."
  use Ecto.Schema
  import Ecto.Changeset

  @max_length 500

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "lobby_messages" do
    field :lobby_id, :binary_id
    field :user_id, :binary_id
    field :body, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Valide `body` ; `lobby_id` et `user_id` sont posés par le serveur, jamais castés."
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_length, count: :codepoints)
    |> validate_no_nul(:body)
  end

  @doc "PostgreSQL refuse l'octet NUL dans un texte : rejeté en 422 plutôt qu'en 500."
  def validate_no_nul(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if String.contains?(value, <<0>>), do: [{field, "is invalid"}], else: []
    end)
  end
end
