defmodule MlMultiplayer.Privacy do
  @moduledoc """
  Export et suppression des données d'un membre dans multiplayer.
  L'export ne contient jamais le journal complet, qui porte le secret et les indices des autres.
  """
  import Ecto.Query

  alias MlMultiplayer.{
    Invite,
    Link,
    Lobbies,
    Lobby,
    Match,
    MatchEvent,
    Member,
    Message,
    Repo,
    Reward
  }

  def export(me) do
    played =
      from e in MatchEvent,
        where: e.type == "match_started",
        where: fragment("? @> ?", e.payload, type(^%{"players" => [me]}, :map)),
        select: e.match_id

    %{
      "lobbies" =>
        Repo.all(
          from m in Member,
            join: l in Lobby,
            on: l.id == m.lobby_id,
            where: m.user_id == ^me,
            order_by: [m.inserted_at, l.id],
            select: %{
              "lobby_id" => l.id,
              "title" => l.title,
              "host" => l.host_id == ^me,
              "membership" => m.status,
              "joined_at" => m.joined_at,
              "lobby_status" => l.status
            }
        ),
      "hosted_lobbies" =>
        Repo.all(
          from l in Lobby,
            where: l.host_id == ^me,
            order_by: [l.inserted_at, l.id],
            select: %{
              "id" => l.id,
              "title" => l.title,
              "visibility" => l.visibility,
              "status" => l.status,
              "inserted_at" => l.inserted_at
            }
        ),
      "messages_sent" =>
        Repo.all(
          from m in Message,
            where: m.user_id == ^me,
            order_by: [m.inserted_at, m.id],
            select: %{
              "id" => m.id,
              "lobby_id" => m.lobby_id,
              "body" => m.body,
              "inserted_at" => m.inserted_at
            }
        ),
      "matches" =>
        Repo.all(
          from x in Match,
            where: x.id in subquery(played),
            order_by: [x.inserted_at, x.id],
            select: %{
              "id" => x.id,
              "lobby_id" => x.lobby_id,
              "status" => x.status,
              "started_at" => x.inserted_at,
              "finished_at" => x.finished_at
            }
        ),
      "attempts" =>
        Repo.all(
          from e in MatchEvent,
            where: e.user_id == ^me and e.type == "attempt",
            order_by: [e.inserted_at, e.seq],
            select: %{
              "match_id" => e.match_id,
              "sequence" => e.payload["sequence"],
              "marks" => e.payload["marks"],
              "inserted_at" => e.inserted_at
            }
        ),
      "rewards" =>
        Repo.all(
          from r in Reward,
            where: r.user_id == ^me,
            order_by: [r.inserted_at, r.id],
            select: %{
              "match_id" => r.match_id,
              "amount" => r.amount,
              "status" => r.status,
              "awarded_at" => r.awarded_at
            }
        ),
      "invites" =>
        Repo.all(
          from i in Invite,
            where: i.inviter_id == ^me or i.invitee_id == ^me,
            order_by: [i.inserted_at, i.id],
            select: %{
              "lobby_id" => i.lobby_id,
              "inviter_id" => i.inviter_id,
              "invitee_id" => i.invitee_id,
              "status" => i.status,
              "inserted_at" => i.inserted_at
            }
        ),
      "links_created" =>
        Repo.all(
          from k in Link,
            where: k.created_by == ^me,
            order_by: [k.inserted_at, k.id],
            select: %{
              "lobby_id" => k.lobby_id,
              "max_uses" => k.max_uses,
              "uses" => k.uses,
              "expires_at" => k.expires_at,
              "revoked_at" => k.revoked_at,
              "inserted_at" => k.inserted_at
            }
        )
    }
  end

  @doc "Fait quitter ses salons au membre et supprime ses invitations, liens et récompenses (idempotent)."
  def delete(me) do
    lobby_ids =
      Repo.all(
        from m in Member,
          join: l in Lobby,
          on: l.id == m.lobby_id,
          where: m.user_id == ^me and m.status in ["active", "pending"] and l.status != "closed",
          select: l.id
      )

    # chemin normal d'un départ : transfert d'hôte, fermeture du salon vide, partie reprise ou interrompue
    Enum.each(lobby_ids, &Lobbies.leave(me, &1))

    Repo.transact(fn ->
      Repo.delete_all(from i in Invite, where: i.inviter_id == ^me or i.invitee_id == ^me)
      Repo.delete_all(from k in Link, where: k.created_by == ^me)
      # l'XP est effacée par learning : une récompense en attente n'est plus livrée
      Repo.delete_all(from r in Reward, where: r.user_id == ^me)
      {:ok, me}
    end)

    :ok
  end
end
