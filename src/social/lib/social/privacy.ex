defmodule MlSocial.Privacy do
  @moduledoc """
  Export et suppression des données d'un membre dans social. L'export ne contient jamais les messages des autres.
  """
  import Ecto.Query

  alias MlSocial.{
    Accounts,
    Attachments,
    Block,
    Conversation,
    Friendship,
    Groups,
    Member,
    Message,
    Repo,
    Report,
    Setting,
    Settings
  }

  def export(me) do
    friendships =
      Repo.all(from f in Friendship, where: f.requester_id == ^me or f.addressee_id == ^me)

    other = fn f -> if f.requester_id == me, do: f.addressee_id, else: f.requester_id end
    {accepted, pending} = Enum.split_with(friendships, &(&1.status == "accepted"))
    profiles = Accounts.users(Enum.map(accepted, other))

    conversations =
      Repo.all(
        from c in Conversation,
          join: m in Member,
          on: m.conversation_id == c.id and m.user_id == ^me,
          order_by: [c.inserted_at, c.id],
          select: {c, m}
      )

    %{
      "friends" =>
        for f <- accepted do
          id = other.(f)
          %{"user_id" => id, "username" => profiles[id]["username"], "since" => f.updated_at}
        end,
      "friend_requests" =>
        for f <- pending do
          direction = if f.requester_id == me, do: "sent", else: "received"
          %{"direction" => direction, "user_id" => other.(f), "inserted_at" => f.inserted_at}
        end,
      "blocks" =>
        Repo.all(
          from b in Block,
            where: b.blocker_id == ^me,
            order_by: b.inserted_at,
            select: %{"user_id" => b.blocked_id, "inserted_at" => b.inserted_at}
        ),
      "settings" => Setting.to_map(Settings.get(me)),
      "conversations" =>
        for {c, member} <- conversations do
          %{
            "id" => c.id,
            "kind" => c.kind,
            "name" => c.name,
            "role" => if(c.owner_id == me, do: "owner", else: "member"),
            "with_user_id" => Conversation.other(c, me),
            "inserted_at" => c.inserted_at,
            "joined_at" => member.joined_at,
            "last_read_at" => member.last_read_at,
            "muted_until" => member.muted_until
          }
        end,
      "messages_sent" =>
        Repo.all(
          from m in Message,
            left_join: a in assoc(m, :attachment),
            where: m.sender_id == ^me,
            order_by: [m.inserted_at, m.id],
            select: %{
              "id" => m.id,
              "conversation_id" => m.conversation_id,
              "kind" => m.kind,
              "body" => m.body,
              "system" => m.system,
              "attachment_id" => a.id,
              "inserted_at" => m.inserted_at
            }
        ),
      "attachments_sent" => Attachments.export(me),
      "reports_filed" =>
        Repo.all(
          from r in Report,
            where: r.reporter_id == ^me,
            order_by: [r.inserted_at, r.id],
            select: %{
              "target_type" => r.target_type,
              "target_id" => r.target_id,
              "reason" => r.reason,
              "details" => r.details,
              "inserted_at" => r.inserted_at
            }
        )
    }
  end

  @doc "Supprime les fichiers, groupes, relations et appartenances du membre, en gardant ses messages (idempotent)."
  def delete(me) do
    Attachments.erase(me)

    groups =
      Repo.all(
        from c in Conversation,
          join: m in Member,
          on: m.conversation_id == c.id and m.user_id == ^me,
          where: c.kind == "group",
          select: c.id
      )

    Enum.each(groups, &Groups.leave(me, &1))

    {:ok, contacts} =
      Repo.transact(fn ->
        {_, friends} =
          Repo.delete_all(
            from(f in Friendship,
              where: f.requester_id == ^me or f.addressee_id == ^me,
              select: [f.requester_id, f.addressee_id]
            )
          )

        {_, blocks} =
          Repo.delete_all(
            from(b in Block,
              where: b.blocker_id == ^me or b.blocked_id == ^me,
              select: [b.blocker_id, b.blocked_id]
            )
          )

        Repo.delete_all(from m in Member, where: m.user_id == ^me)
        Repo.delete_all(from s in Setting, where: s.user_id == ^me)
        {:ok, (friends ++ blocks) |> List.flatten() |> Enum.uniq() |> List.delete(me)}
      end)

    for id <- contacts,
        do: MlShared.Events.broadcast(MlShared.Events.user(id), {:friendship_changed, id})

    :ok
  end
end
