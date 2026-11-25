defmodule MlSocial.Notify do
  @moduledoc """
  Notifications des catégories `messages` et `friends`, envoyées au mieux.
  Le texte d'un message n'est jamais transmis, seulement l'identifiant de la conversation.
  """
  import Ecto.Query
  alias MlShared.Notifications
  alias MlSocial.{Conversation, Delivery, Friendship, Member, Message, Repo}

  @doc "Nouveau message texte de `message.sender_id` dans `conversation`."
  def new_message(%Conversation{} = conversation, %Message{kind: "text"} = message) do
    Notifications.async(fn ->
      now = DateTime.utc_now()

      members =
        Repo.all(
          from m in Member,
            where: m.conversation_id == ^conversation.id and m.user_id != ^message.sender_id
        )

      blocked = Delivery.blocked_with(message.sender_id, Enum.map(members, & &1.user_id))

      for member <- members,
          not Member.muted?(member, now),
          not MapSet.member?(blocked, member.user_id),
          not read_since?(member, message.inserted_at) do
        each(%{
          user_id: member.user_id,
          category: "messages",
          kind: "message_received",
          actor_id: message.sender_id,
          params: conversation_params(conversation),
          dedupe_key: "conversation:#{conversation.id}",
          event_id: "message:#{message.id}",
          occurred_at: message.inserted_at
        })
      end
    end)
  end

  def new_message(_conversation, _message), do: :ok

  defp read_since?(%Member{last_read_at: nil}, _at), do: false
  defp read_since?(%Member{last_read_at: read}, at), do: DateTime.compare(read, at) != :lt

  defp conversation_params(%Conversation{kind: "group"} = c),
    do: %{conversation_id: c.id, conversation_kind: "group", group_name: c.name}

  defp conversation_params(%Conversation{} = c),
    do: %{conversation_id: c.id, conversation_kind: "direct"}

  @doc "`user_id` a lu la conversation jusqu'à `read_at`."
  def read(user_id, conversation_id, read_at),
    do: read_keys(user_id, ["conversation:#{conversation_id}"], read_at)

  @doc "`user_id` n'est plus membre du groupe : ses notifications de ce groupe sont marquées lues."
  def left_group(user_id, conversation_id),
    do:
      read_keys(
        user_id,
        ["conversation:#{conversation_id}", "group:#{conversation_id}:added"],
        DateTime.utc_now()
      )

  defp read_keys(user_id, keys, read_at) do
    for key <- keys do
      Notifications.async(fn -> Notifications.read(user_id, key, read_at) end)
    end

    :ok
  end

  @doc "Demande d'ami en attente de `friendship.requester_id` vers `friendship.addressee_id`."
  def friend_request(%Friendship{status: "pending"} = f) do
    each(%{
      user_id: f.addressee_id,
      category: "friends",
      kind: "friend_request_received",
      actor_id: f.requester_id,
      params: %{request_id: f.id},
      dedupe_key: "friend_request:#{f.id}"
    })
  end

  @doc "Demande `friendship` acceptée par son destinataire : le demandeur est prévenu."
  def friend_accepted(%Friendship{status: "accepted"} = f) do
    each(%{
      user_id: f.requester_id,
      category: "friends",
      kind: "friend_request_accepted",
      actor_id: f.addressee_id,
      dedupe_key: "friendship:#{f.id}:accepted"
    })

    request_closed(f)
  end

  @doc "La demande n'est plus en attente (acceptée, refusée, annulée) : sa notification est marquée lue."
  def request_closed(%Friendship{} = f),
    do: read_keys(f.addressee_id, ["friend_request:#{f.id}"], DateTime.utc_now())

  @doc "`user_id` a été ajouté au groupe `conversation` par `actor_id`."
  def group_added(%Conversation{kind: "group"} = conversation, user_id, actor_id) do
    each(%{
      user_id: user_id,
      category: "friends",
      kind: "group_added",
      actor_id: actor_id,
      params: %{conversation_id: conversation.id, group_name: conversation.name},
      dedupe_key: "group:#{conversation.id}:added",
      event_id: "group_added:#{Ecto.UUID.generate()}"
    })
  end

  @doc "Blocage entre `a` et `b` : plus aucune notification de l'un chez l'autre."
  def blocked(a, b) do
    Notifications.async(fn -> Notifications.clear_between(a, b) end)
  end

  # une tâche par notification : un destinataire lent à servir n'en retarde aucun autre
  defp each(notification) do
    Notifications.async(fn -> Notifications.notify(notification) end)
  end
end
