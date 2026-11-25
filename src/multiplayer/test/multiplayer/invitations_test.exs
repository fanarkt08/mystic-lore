defmodule MlMultiplayer.InvitationsTest do
  use MlMultiplayer.DataCase, async: true
  alias MlMultiplayer.{Invitations, Invite, Link, Lobbies, Member}

  describe "invitations d'amis" do
    test "seuls les amis peuvent être invités ; notification temps réel sur user:<invité>" do
      host = uuid()
      lobby = lobby!(host, %{"visibility" => "private"})
      [friend, stranger] = [uuid(), uuid()]
      stub_services(friends: [{host, friend}])
      MlShared.Events.subscribe("user:#{friend}")

      assert {:error, :not_friends} = Invitations.invite(host, lobby.id, stranger)

      assert {:ok, %Invite{id: id, status: "pending"}} =
               Invitations.invite(host, lobby.id, friend)

      lobby_id = lobby.id

      assert_receive {:lobby_invite,
                      %{
                        "id" => ^id,
                        "lobby_id" => ^lobby_id,
                        "lobby_title" => "Rune night",
                        "inviter_id" => ^host
                      }}

      assert_received {:service, "GET", "/api/internal/can-contact", _}

      # l'invitation rend le salon privé visible à l'invité, puis l'acceptation l'admet sans approbation
      assert {:ok, _, :invited} = Lobbies.fetch(friend, lobby.id)
      assert {:ok, [%{invite: %Invite{id: ^id}}]} = Invitations.list_for(friend)
      assert {:ok, ^lobby_id} = Invitations.accept(friend, id)
      assert {:ok, _, :player} = Lobbies.fetch(friend, lobby.id)
      assert {:ok, []} = Invitations.list_for(friend)
      assert {:error, :not_found} = Invitations.accept(friend, id)
    end

    test "centre de notifications : une notification lobby_invite, marquée lue à l'acceptation" do
      host = uuid()
      lobby = lobby!(host, %{"title" => "Moonlit relay"})
      friend = uuid()
      stub_services(friends: [{host, friend}])

      assert {:ok, %Invite{id: id}} = Invitations.invite(host, lobby.id, friend)
      lobby_id = lobby.id

      assert_received {:service, "POST", "/api/internal/notifications",
                       %{
                         "user_id" => ^friend,
                         "category" => "multiplayer",
                         "kind" => "lobby_invite",
                         "actor_id" => ^host,
                         "params" => %{
                           "invite_id" => ^id,
                           "lobby_id" => ^lobby_id,
                           "lobby_title" => "Moonlit relay"
                         },
                         "dedupe_key" => key,
                         "event_id" => "lobby_invite:" <> _
                       }}

      assert key == "lobby_invite:#{id}"
      assert {:ok, ^lobby_id} = Invitations.accept(friend, id)

      assert_received {:service, "POST", "/api/internal/notifications/read",
                       %{"user_id" => ^friend, "dedupe_key" => ^key}}
    end

    @tag :capture_log
    test "centre injoignable : l'invitation est quand même faite" do
      host = uuid()
      lobby = lobby!(host)
      friend = uuid()
      stub_services(friends: [{host, friend}], notifications: :down)
      assert {:ok, %Invite{status: "pending"}} = Invitations.invite(host, lobby.id, friend)
    end

    test "refus d'invitation décidé par social (réglage « personne ») : explicite, rien n'est envoyé" do
      host = uuid()
      lobby = lobby!(host)
      friend = uuid()
      stub_services(invites_closed: [friend])
      MlShared.Events.subscribe("user:#{friend}")

      assert {:error, :lobby_invites_closed} = Invitations.invite(host, lobby.id, friend)
      refute_received {:lobby_invite, _}
      assert {:ok, []} = Invitations.list_for(friend)
    end

    @tag :capture_log
    test "social injoignable : l'invitation est refusée (503), jamais envoyée par défaut" do
      host = uuid()
      lobby = lobby!(host)
      stub_services(social: :down)
      assert {:error, :social_unavailable} = Invitations.invite(host, lobby.id, uuid())
    end

    test "seul l'hôte invite ; pas soi-même ; pas un membre déjà présent" do
      host = uuid()
      lobby = lobby!(host)
      guest = join!(lobby, uuid())

      assert {:error, :forbidden} = Invitations.invite(guest, lobby.id, uuid())
      assert {:error, {:invalid, %{user_id: _}}} = Invitations.invite(host, lobby.id, host)
      assert {:error, :already_member} = Invitations.invite(host, lobby.id, guest)
    end

    test "blocage : ami bloqué, ou bloqué avec un autre membre, ne peut pas être invité" do
      host = uuid()
      lobby = lobby!(host)
      member = join!(lobby, uuid())
      [blocked_friend, blocked_by_member] = [uuid(), uuid()]
      stub_services(blocks: [{blocked_friend, host}, {member, blocked_by_member}])

      assert {:error, :blocked} = Invitations.invite(host, lobby.id, blocked_friend)
      assert {:error, :blocked} = Invitations.invite(host, lobby.id, blocked_by_member)
    end

    test "invitations listées : hors salon fermé et hors invitant bloqué depuis ; refus par l'invité" do
      [host, other_host, me] = [uuid(), uuid(), uuid()]
      lobby = lobby!(host)
      other = lobby!(other_host)
      {:ok, first} = Invitations.invite(host, lobby.id, me)
      {:ok, second} = Invitations.invite(other_host, other.id, me)

      stub_services(blocks: [{me, other_host}])
      assert {:ok, [%{invite: %{id: id}}]} = Invitations.list_for(me)
      assert id == first.id

      assert {:error, :not_found} = Invitations.decline(uuid(), first.id)
      assert :ok = Invitations.decline(me, first.id)
      assert {:ok, []} = Invitations.list_for(me)
      assert %Invite{status: "pending"} = Repo.reload!(second)
    end
  end

  describe "liens temporaires" do
    test "jeton rendu une fois et stocké haché ; rejoindre consomme un usage, sans approbation" do
      host = uuid()
      lobby = lobby!(host, %{"visibility" => "private", "requires_approval" => true})

      # salon privé : invisible (404) pour un non-membre ; un joueur non hôte est refusé (403)
      assert {:error, :not_found} = Invitations.create_link(uuid(), lobby.id, %{})
      assert {:ok, link, token} = Invitations.create_link(host, lobby.id, %{"max_uses" => 2})
      assert link.token_hash == :crypto.hash(:sha256, token)
      refute Repo.reload!(link).token_hash == token

      guest = uuid()
      assert {:ok, %{id: lobby_id}} = Invitations.preview(token)
      assert lobby_id == lobby.id
      assert {:ok, ^lobby_id} = Invitations.join_link(guest, token)
      assert {:ok, _, :player} = Lobbies.fetch(guest, lobby.id)
      # déjà membre : aucun usage consommé
      assert {:ok, ^lobby_id} = Invitations.join_link(guest, token)
      assert Repo.reload!(link).uses == 1
    end

    test "expiré, révoqué, épuisé : refus explicite, sans rien révéler du salon" do
      host = uuid()
      lobby = lobby!(host, %{"visibility" => "private"})
      past = DateTime.add(DateTime.utc_now(), -3600)

      {:ok, _, expired} =
        Invitations.create_link(host, lobby.id, %{"expires_in_minutes" => 5}, past)

      assert {:error, :expired} = Invitations.preview(expired)
      assert {:error, :expired} = Invitations.join_link(uuid(), expired)

      {:ok, link, revoked} = Invitations.create_link(host, lobby.id, %{})
      assert {:error, :not_found} = Invitations.revoke_link(uuid(), lobby.id, link.id)
      assert :ok = Invitations.revoke_link(host, lobby.id, link.id)
      assert :ok = Invitations.revoke_link(host, lobby.id, link.id)
      assert {:error, :revoked} = Invitations.preview(revoked)
      assert {:error, :revoked} = Invitations.join_link(uuid(), revoked)

      {:ok, _, single} = Invitations.create_link(host, lobby.id, %{"max_uses" => 1})
      assert {:ok, _} = Invitations.join_link(uuid(), single)
      assert {:error, :exhausted} = Invitations.preview(single)
      assert {:error, :exhausted} = Invitations.join_link(uuid(), single)

      assert {:error, :not_found} = Invitations.preview("unknown-token-0123456789")
      assert {:error, :not_found} = Invitations.preview(nil)
      assert {:error, :not_found} = Invitations.revoke_link(host, lobby.id, uuid())
    end

    test "paramètres bornés et au plus 5 liens actifs par salon" do
      host = uuid()
      lobby = lobby!(host)

      assert {:error, {:invalid, %{max_uses: _, expires_in_minutes: _}}} =
               Invitations.create_link(host, lobby.id, %{
                 "max_uses" => 0,
                 "expires_in_minutes" => "1"
               })

      for _ <- 1..5, do: {:ok, _, _} = Invitations.create_link(host, lobby.id, %{})
      assert {:error, :too_many_links} = Invitations.create_link(host, lobby.id, %{})
    end

    test "un lien n'outrepasse ni l'exclusion, ni le blocage, ni la capacité ; salon fermé → closed" do
      host = uuid()
      lobby = lobby!(host, %{"max_players" => 2})
      kicked = join!(lobby, uuid())
      :ok = Lobbies.kick(host, lobby.id, kicked)
      {:ok, _, token} = Invitations.create_link(host, lobby.id, %{"max_uses" => 10})

      assert {:error, :banned} = Invitations.join_link(kicked, token)

      blocked = uuid()
      stub_services(blocks: [{host, blocked}])
      assert {:error, :blocked} = Invitations.join_link(blocked, token)

      stub_services()
      assert {:ok, _} = Invitations.join_link(uuid(), token)
      assert {:error, :full} = Invitations.join_link(uuid(), token)
      assert %Link{uses: 1} = Repo.get_by!(Link, lobby_id: lobby.id)

      for user <- Lobbies.active_ids(lobby.id), do: :ok = Lobbies.leave(user, lobby.id)
      assert {:error, :closed} = Invitations.preview(token)
      assert %Member{status: "kicked"} = Repo.get_by!(Member, lobby_id: lobby.id, user_id: kicked)
    end
  end
end
