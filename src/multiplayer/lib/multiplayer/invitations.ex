defmodule MlMultiplayer.Invitations do
  @moduledoc """
  Invitations d'amis et liens temporaires d'un salon. Un lien expiré, révoqué ou épuisé ne révèle rien du salon.
  """
  import Ecto.Query
  alias MlMultiplayer.{Invite, Link, Lobbies, Lobby, Member, Repo, Social}
  alias MlShared.Events

  @max_active_links 5

  ## Invitations d'amis

  def invite(host_id, lobby_id, invitee_id) do
    with {:ok, lobby, _} <- Lobbies.authorize(host_id, lobby_id, [:host]),
         {:ok, invitee} <- Lobbies.other(host_id, invitee_id),
         :ok <- Social.can_invite(host_id, invitee),
         {:ok, blocked} <- Social.blocked_ids(invitee),
         :ok <- invitable(lobby.id, invitee, blocked) do
      now = DateTime.utc_now()

      invite =
        Repo.insert!(
          %Invite{
            lobby_id: lobby.id,
            inviter_id: host_id,
            invitee_id: invitee,
            status: "pending"
          },
          on_conflict: [set: [status: "pending", inviter_id: host_id, updated_at: now]],
          conflict_target: [:lobby_id, :invitee_id],
          returning: true
        )

      Events.broadcast(
        Events.user(invitee),
        {:lobby_invite,
         %{
           "id" => invite.id,
           "lobby_id" => lobby.id,
           "lobby_title" => lobby.title,
           "inviter_id" => host_id
         }}
      )

      Lobbies.changed(lobby.id)
      notify(invite, lobby)
      {:ok, invite}
    end
  end

  # centre de notifications, au mieux : une invitation (renouvelée après un refus : nouvelle occurrence)
  defp notify(invite, lobby) do
    MlShared.Notifications.async(fn ->
      MlShared.Notifications.notify(%{
        user_id: invite.invitee_id,
        category: "multiplayer",
        kind: "lobby_invite",
        actor_id: invite.inviter_id,
        params: %{invite_id: invite.id, lobby_id: lobby.id, lobby_title: lobby.title},
        dedupe_key: "lobby_invite:#{invite.id}",
        event_id:
          "lobby_invite:#{invite.id}:#{DateTime.to_unix(invite.updated_at, :microsecond)}",
        occurred_at: invite.updated_at
      })
    end)
  end

  # invitation acceptée ou refusée : sa notification est marquée lue
  defp invite_closed(invite) do
    MlShared.Notifications.async(fn ->
      MlShared.Notifications.read(invite.invitee_id, "lobby_invite:#{invite.id}")
    end)
  end

  defp invitable(lobby_id, invitee, blocked) do
    case Repo.get_by(Member, lobby_id: lobby_id, user_id: invitee) do
      %Member{status: "active"} ->
        {:error, :already_member}

      %Member{status: "kicked"} ->
        {:error, :banned}

      _ ->
        if Enum.any?(Lobbies.active_ids(lobby_id), &(&1 in blocked)),
          do: {:error, :blocked},
          else: :ok
    end
  end

  @doc "Invitations en attente de `user_id` (salons non fermés, hors hôte bloqué, hors salon dont il est exclu)."
  def list_for(user_id) do
    with {:ok, blocked} <- Social.blocked_ids(user_id) do
      rows =
        Repo.all(
          from i in Invite,
            join: l in Lobby,
            on: l.id == i.lobby_id,
            left_join: m in Member,
            on: m.lobby_id == i.lobby_id and m.user_id == ^user_id,
            where: i.invitee_id == ^user_id and i.status == "pending" and l.status != "closed",
            where: i.inviter_id not in ^blocked,
            where: is_nil(m.status) or m.status not in ["active", "kicked"],
            order_by: [desc: i.updated_at],
            select: {i, l}
        )

      counts = Lobbies.counts(Enum.map(rows, &elem(&1, 1).id))

      {:ok,
       for {invite, lobby} <- rows do
         %{invite: invite, lobby: lobby, member_count: Map.get(counts, lobby.id, 0)}
       end}
    end
  end

  @doc "L'invité accepte : admission directe (capacité, blocages et exclusion revérifiés), `{:ok, lobby_id}`."
  def accept(user_id, invite_id) do
    with {:ok, invite} <- pending_invite(user_id, invite_id),
         {:ok, blocked} <- Social.blocked_ids(user_id),
         {:ok, :joined} <- Lobbies.admit(invite.lobby_id, user_id, :direct, blocked) do
      invite_closed(invite)
      {:ok, invite.lobby_id}
    end
  end

  def decline(user_id, invite_id) do
    with {:ok, invite} <- pending_invite(user_id, invite_id) do
      Repo.update_all(from(i in Invite, where: i.id == ^invite.id and i.status == "pending"),
        set: [status: "declined", updated_at: DateTime.utc_now()]
      )

      Lobbies.changed(invite.lobby_id)
      invite_closed(invite)
      :ok
    end
  end

  defp pending_invite(user_id, invite_id) do
    with {:ok, id} <- MlMultiplayer.cast_uuid(invite_id),
         %Invite{} = invite <-
           Repo.get_by(Invite, id: id, invitee_id: user_id, status: "pending") do
      {:ok, invite}
    else
      _ -> {:error, :not_found}
    end
  end

  ## Liens temporaires

  @doc """
  Crée un lien (`max_uses` 1..20, défaut 5 ; `expires_in_minutes` 5..10 080, défaut 60) et renvoie
  `{:ok, link, token}` : le jeton en clair n'existe qu'ici.
  """
  def create_link(host_id, lobby_id, attrs, now \\ DateTime.utc_now()) do
    with {:ok, lobby, _} <- Lobbies.authorize(host_id, lobby_id, [:host]),
         {:ok, max_uses, minutes} <- link_params(attrs) do
      active =
        Repo.aggregate(
          from(l in Link,
            where: l.lobby_id == ^lobby.id and is_nil(l.revoked_at) and l.expires_at > ^now,
            where: l.uses < l.max_uses
          ),
          :count
        )

      if active >= @max_active_links do
        {:error, :too_many_links}
      else
        token = Link.new_token()

        link =
          Repo.insert!(%Link{
            lobby_id: lobby.id,
            created_by: host_id,
            token_hash: Link.hash(token),
            max_uses: max_uses,
            expires_at: DateTime.add(now, minutes * 60),
            inserted_at: now
          })

        {:ok, link, token}
      end
    end
  end

  defp link_params(attrs) do
    max_uses = Map.get(attrs, "max_uses", 5)
    minutes = Map.get(attrs, "expires_in_minutes", 60)

    errors =
      Enum.reject(
        [
          max_uses: valid?(max_uses, 1..20) || ["must be between 1 and 20"],
          expires_in_minutes: valid?(minutes, 5..10_080) || ["must be between 5 and 10080"]
        ],
        &(elem(&1, 1) == true)
      )

    if errors == [], do: {:ok, max_uses, minutes}, else: {:error, {:invalid, Map.new(errors)}}
  end

  defp valid?(value, range), do: is_integer(value) and value in range

  @doc "Révoque un lien du salon (idempotent : une révocation antérieure garde sa date)."
  def revoke_link(host_id, lobby_id, link_id) do
    now = DateTime.utc_now()

    with {:ok, lobby, _} <- Lobbies.authorize(host_id, lobby_id, [:host]),
         {:ok, id} <- MlMultiplayer.cast_uuid(link_id),
         {1, _} <-
           Repo.update_all(
             from(l in Link,
               where: l.id == ^id and l.lobby_id == ^lobby.id,
               update: [set: [revoked_at: coalesce(l.revoked_at, ^now)]]
             ),
             []
           ) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Aperçu d'un lien avant de rejoindre : `{:ok, lobby}` s'il est utilisable, sinon `{:error, raison}`, sans
  aucune information sur le salon.
  """
  def preview(token, now \\ DateTime.utc_now()) do
    with {:ok, link} <- find_link(token),
         :ok <- usable(link, now) do
      case Repo.get(Lobby, link.lobby_id) do
        %Lobby{status: "closed"} -> {:error, :closed}
        lobby -> {:ok, lobby}
      end
    end
  end

  @doc "Rejoint par lien (consomme un usage, sauf pour un membre déjà présent) : `{:ok, lobby_id}`."
  def join_link(user_id, token, now \\ DateTime.utc_now()) do
    with {:ok, link} <- find_link(token),
         {:ok, blocked} <- Social.blocked_ids(user_id),
         {:ok, lobby_id} <- Repo.transact(fn -> join_locked(link.id, user_id, blocked, now) end) do
      Lobbies.changed(lobby_id)
      {:ok, lobby_id}
    end
  end

  defp join_locked(link_id, user_id, blocked, now) do
    link = Repo.one!(from l in Link, where: l.id == ^link_id, lock: "FOR UPDATE")
    member = Repo.get_by(Member, lobby_id: link.lobby_id, user_id: user_id)

    with false <- match?(%Member{status: "active"}, member),
         :ok <- usable(link, now),
         {:ok, :joined} <- Lobbies.admit_locked(link.lobby_id, user_id, :direct, blocked) do
      Repo.update_all(from(l in Link, where: l.id == ^link.id), inc: [uses: 1])
      {:ok, link.lobby_id}
    else
      true -> {:ok, link.lobby_id}
      {:error, _} = error -> error
    end
  end

  defp find_link(token) when is_binary(token) and byte_size(token) in 16..128 do
    case Repo.get_by(Link, token_hash: Link.hash(token)) do
      nil -> {:error, :not_found}
      link -> {:ok, link}
    end
  end

  defp find_link(_token), do: {:error, :not_found}

  defp usable(link, now) do
    case Link.state(link, now) do
      "active" -> :ok
      "expired" -> {:error, :expired}
      "revoked" -> {:error, :revoked}
      "exhausted" -> {:error, :exhausted}
    end
  end
end
