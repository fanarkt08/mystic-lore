defmodule MlSocial.Fixtures do
  @moduledoc "Données de test : membres aléatoires (aucune collision entre tests asynchrones)."
  alias MlSocial.{Chat, Friends, Groups, Message, Repo, Settings}

  def uuid, do: Ecto.UUID.generate()

  def befriend(a, b) do
    {:ok, %{status: "pending", id: id}} = Friends.send_request(a, b)
    {:ok, friendship} = Friends.accept(b, id)
    friendship
  end

  @doc "Deux amis et leur conversation."
  def conversation_between(a, b) do
    befriend(a, b)
    {:ok, %{conversation: conversation}} = Chat.open(a, b)
    conversation
  end

  @doc "Groupe de `owner` avec `members` (devenus ses amis s'ils ne l'étaient pas) : la conversation."
  def group!(owner, members, name \\ "Moonlit study circle") do
    for member <- members, not Friends.friends?(owner, member), do: befriend(owner, member)

    {:ok, %{conversation: conversation}} =
      Groups.create(owner, %{"name" => name, "member_ids" => members})

    conversation
  end

  def setting!(user, attrs) do
    {:ok, setting} = Settings.update(user, attrs)
    setting
  end

  @doc "Corps d'envoi d'une pièce jointe (`POST /api/conversations/:id/messages`)."
  def attachment(bytes, filename \\ "file.bin", alt \\ nil),
    do: %{"data_base64" => Base.encode64(bytes), "filename" => filename, "alt" => alt}

  @doc "Insère directement des messages horodatés (`{sender, body, seconds_ago}`), sans événement."
  def insert_messages(conversation, rows) do
    now = DateTime.utc_now()

    messages =
      for {sender, body, seconds_ago} <- rows do
        %{
          id: uuid(),
          conversation_id: conversation.id,
          sender_id: sender,
          body: body,
          inserted_at: DateTime.add(now, -seconds_ago, :second)
        }
      end

    Repo.insert_all(Message, messages)
    messages
  end
end
