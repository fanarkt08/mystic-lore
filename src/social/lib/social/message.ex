defmodule MlSocial.Message do
  @moduledoc """
  Message d'une conversation : `text` de 1 à 2000 caractères (facultatif avec une pièce jointe), ou `system`
  pour un événement de groupe, rédigé et traduit par web.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias MlSocial.Attachment

  @max_length 2000

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "messages" do
    field :conversation_id, :binary_id
    field :sender_id, :binary_id
    field :kind, :string, default: "text"
    field :body, :string
    field :system, :map
    # retrait par la modération (suppression logique : le texte n'est plus jamais renvoyé)
    field :removed_at, :utc_datetime_usec
    field :removed_by, :binary_id
    has_one :attachment, Attachment
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Valide `body` (facultatif quand le message porte une pièce jointe) ; `conversation_id` et `sender_id` sont
  posés par le serveur, jamais castés.
  """
  def changeset(message, attrs, attachment? \\ false) do
    message
    |> cast(attrs, [:body])
    |> then(&if(attachment?, do: &1, else: validate_required(&1, [:body])))
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, max: @max_length, count: :codepoints)
    |> validate_no_nul(:body)
  end

  @doc "Message système d'un groupe (texte rédigé par web)."
  def system(conversation_id, actor_id, event, fields \\ %{}) do
    %__MODULE__{
      conversation_id: conversation_id,
      sender_id: actor_id,
      kind: "system",
      system: Map.merge(%{"event" => event, "actor_id" => actor_id}, fields)
    }
  end

  @doc "PostgreSQL refuse l'octet NUL dans un texte : on le rejette en 422 plutôt qu'en 500."
  def validate_no_nul(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if String.contains?(value, <<0>>), do: [{field, "is invalid"}], else: []
    end)
  end

  @doc "Forme du contrat, sans texte ni pièce jointe pour un message retiré ou masqué."
  def to_map(%__MODULE__{} = m, hidden \\ false) do
    removed = not is_nil(m.removed_at)
    masked = removed or (hidden and m.kind == "text")

    %{
      "id" => m.id,
      "conversation_id" => m.conversation_id,
      "kind" => m.kind,
      "sender_id" => if(hidden and m.kind == "text", do: nil, else: m.sender_id),
      "body" => if(masked, do: nil, else: m.body),
      "removed" => removed,
      "hidden" => hidden and m.kind == "text",
      "attachment" => if(masked, do: nil, else: attachment(m.attachment)),
      "system" => m.system,
      "inserted_at" => DateTime.to_iso8601(m.inserted_at)
    }
  end

  defp attachment(%Attachment{} = a), do: Attachment.to_map(a)
  defp attachment(_none), do: nil
end
