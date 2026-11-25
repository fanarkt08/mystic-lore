defmodule MlSocialWeb.ConversationJSON do
  @moduledoc "Formes JSON des conversations, enrichies par accounts en une seule requête par réponse."
  alias MlSocial.{Accounts, Conversation, Member, Message}

  def conversations(summaries, me) do
    users =
      Accounts.users(Enum.flat_map(summaries, fn s -> Enum.map(s.members, & &1.user_id) end))

    Enum.map(summaries, &conversation(&1, me, users))
  end

  def conversation(summary, me), do: hd(conversations([summary], me))

  defp conversation(%{conversation: c} = s, me, users) do
    {muted, muted_until} = Member.mute_state(s.member)

    %{
      id: c.id,
      kind: c.kind,
      name: c.name,
      owner_id: c.owner_id,
      other: if(c.kind == "direct", do: users[Conversation.other(c, me)]),
      members:
        for m <- s.members do
          %{
            user: users[m.user_id],
            role: if(m.user_id == c.owner_id, do: "owner", else: "member"),
            joined_at: m.joined_at
          }
        end,
      last_message:
        s.last_message && Message.to_map(s.last_message, hidden?(c, s, s.last_message)),
      unread: s.unread,
      muted: muted,
      muted_until: muted_until
    }
    |> put_reads(s[:reads])
  end

  defp hidden?(c, s, message),
    do: Conversation.group?(c) and MapSet.member?(s.hidden, message.sender_id)

  # accusés de lecture : seulement dans le détail d'une conversation (GET /api/conversations/:id)
  defp put_reads(map, nil), do: map
  defp put_reads(map, receipts), do: Map.put(map, :read_receipts, receipts)

  @doc "Page d'historique : messages (masqués pour le lecteur si besoin) et membres qu'ils citent."
  def page(page) do
    entries =
      Enum.map(page.entries, &Message.to_map(&1, MapSet.member?(page.hidden, &1.sender_id)))

    ids =
      for e <- entries,
          id <- [
            e["sender_id"]
            | if(e["system"], do: [e["system"]["actor_id"], e["system"]["target_id"]], else: [])
          ],
          is_binary(id),
          uniq: true,
          do: id

    %{entries: entries, next_before: page.next_before, users: Map.values(Accounts.users(ids))}
  end
end
