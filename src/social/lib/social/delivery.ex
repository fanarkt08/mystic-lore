defmodule MlSocial.Delivery do
  @moduledoc """
  Livre les événements de la messagerie membre par membre sur `"user:<id>"`.
  Il n'existe aucun topic de conversation : un membre retiré ne reçoit plus rien.
  """
  import Ecto.Query
  alias MlShared.Events
  alias MlSocial.{Block, Conversation, Member, Message, Repo, Settings}

  def member_ids(conversation_id) do
    Repo.all(
      from m in Member,
        where: m.conversation_id == ^conversation_id,
        order_by: [m.joined_at, m.user_id],
        select: m.user_id
    )
  end

  def new_message(%Conversation{} = conversation, %Message{} = message) do
    members = deliver(conversation, message, :new_message)

    if message.kind == "text" do
      for id <- members,
          id != message.sender_id,
          do: Events.broadcast(Events.user(id), {:unread_changed, id})
    end

    :ok
  end

  def message_removed(%Message{} = message) do
    conversation = Repo.get!(Conversation, message.conversation_id)

    for id <- deliver(conversation, message, :message_removed),
        do: Events.broadcast(Events.user(id), {:unread_changed, id})

    :ok
  end

  defp deliver(conversation, message, tag) do
    members = member_ids(conversation.id)

    hidden =
      if Conversation.group?(conversation) and message.kind == "text",
        do: blocked_with(message.sender_id, members),
        else: MapSet.new()

    for id <- members do
      map = Message.to_map(message, MapSet.member?(hidden, id))
      Events.broadcast(Events.user(id), {tag, map})
    end

    members
  end

  def read(conversation_id, reader, read_at) do
    others = member_ids(conversation_id) -- [reader]
    settings = Settings.for_users([reader | others])

    if settings[reader].read_receipts do
      blocked = blocked_with(reader, others)
      read = %{"user_id" => reader, "read_at" => DateTime.to_iso8601(read_at)}

      for id <- others,
          settings[id].read_receipts,
          not MapSet.member?(blocked, id),
          do: Events.broadcast(Events.user(id), {:messages_read, conversation_id, read})
    end

    :ok
  end

  def changed(conversation_id, also \\ []) do
    for id <- Enum.uniq(member_ids(conversation_id) ++ also),
        do: Events.broadcast(Events.user(id), {:conversation_changed, conversation_id})

    :ok
  end

  @doc "Toutes les conversations de `user_id` changent pour leurs membres (ex. ses accusés de lecture)."
  def conversations_changed(user_id) do
    ids = Repo.all(from m in Member, where: m.user_id == ^user_id, select: m.conversation_id)
    Enum.each(ids, &changed/1)
  end

  @doc "Parmi `ids`, les membres qui ont un blocage avec `user_id` (dans un sens ou l'autre)."
  def blocked_with(user_id, ids) do
    Repo.all(
      from b in Block,
        where:
          (b.blocker_id == ^user_id and b.blocked_id in ^ids) or
            (b.blocked_id == ^user_id and b.blocker_id in ^ids),
        select: {b.blocker_id, b.blocked_id}
    )
    |> MapSet.new(fn {blocker, blocked} -> if blocker == user_id, do: blocked, else: blocker end)
  end
end
