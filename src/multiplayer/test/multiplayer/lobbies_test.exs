defmodule MlMultiplayer.LobbiesTest do
  use MlMultiplayer.DataCase, async: true
  alias MlMultiplayer.{Invitations, Lobbies, Lobby, Member}

  defp member(lobby, user), do: Repo.get_by(Member, lobby_id: lobby.id, user_id: user)

  describe "création" do
    test "valide titre, capacité (2 à 4), visibilité et date programmée (future, UTC)" do
      host = uuid()

      assert {:error, changeset} =
               Lobbies.create(host, %{
                 "title" => " x ",
                 "max_players" => 5,
                 "visibility" => "secret",
                 "starts_at" => "2020-01-01T10:00:00Z"
               })

      assert %{
               title: [_],
               max_players: [_],
               visibility: [_],
               starts_at: ["must be in the future"]
             } =
               errors_on(changeset)

      later = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      lobby = lobby!(host, %{"starts_at" => later, "requires_approval" => true})
      assert %Lobby{status: "waiting", host_id: ^host, requires_approval: true} = lobby
      assert %Member{status: "active"} = member(lobby, host)
    end

    test "au plus 3 salons non fermés par hôte" do
      host = uuid()
      for _ <- 1..3, do: lobby!(host)

      assert {:error, :too_many_lobbies} =
               Lobbies.create(host, %{
                 "title" => "Fourth",
                 "visibility" => "open",
                 "max_players" => 2
               })

      [first | _] = Lobbies.list_mine(host)
      :ok = Lobbies.leave(host, first.lobby.id)

      assert {:ok, _} =
               Lobbies.create(host, %{
                 "title" => "Fourth",
                 "visibility" => "open",
                 "max_players" => 2
               })
    end
  end

  describe "visibilité" do
    test "privé : invisible (404) pour un non-membre ; ouvert : visible en spectateur" do
      host = uuid()
      private = lobby!(host, %{"visibility" => "private"})
      open = lobby!(host)
      stranger = uuid()

      assert {:error, :not_found} = Lobbies.fetch(stranger, private.id)
      assert {:error, :not_found} = Lobbies.join(stranger, private.id)
      assert {:ok, _, :spectator} = Lobbies.fetch(stranger, open.id)
      assert {:ok, _, :host} = Lobbies.fetch(host, private.id)
      assert {:error, :not_found} = Lobbies.fetch(stranger, "not-a-uuid")
      assert {:error, :not_found} = Lobbies.fetch(stranger, uuid())
    end

    test "liste ouverte : hors salons privés, siens, et hôtes bloqués" do
      [me, friend, blocker] = [uuid(), uuid(), uuid()]
      visible = lobby!(friend)
      lobby!(friend, %{"visibility" => "private"})
      lobby!(blocker)
      lobby!(me)
      stub_services(blocks: [{blocker, me}])

      assert {:ok, %{entries: entries, total: total}} = Lobbies.list_open(me, 1)
      ids = Enum.map(entries, & &1.lobby.id)
      assert visible.id in ids
      refute Enum.any?(entries, &(&1.lobby.host_id in [blocker, me]))
      assert total == length(entries)
    end

    test "social injoignable : liste refusée plutôt qu'ouverte sans filtrage" do
      stub_services(social: :down)
      assert {:error, :social_unavailable} = Lobbies.list_open(uuid(), 1)
    end
  end

  describe "rejoindre" do
    test "salon ouvert : membre immédiat, idempotent ; plein → full" do
      lobby = lobby!(uuid(), %{"max_players" => 2})
      guest = uuid()
      assert {:ok, :joined} = Lobbies.join(guest, lobby.id)
      assert {:ok, :joined} = Lobbies.join(guest, lobby.id)
      assert {:error, :full} = Lobbies.join(uuid(), lobby.id)
    end

    test "approbation : demande en attente, puis acceptée ou refusée par l'hôte seulement" do
      host = uuid()
      lobby = lobby!(host, %{"requires_approval" => true})
      [a, b] = [uuid(), uuid()]

      assert {:ok, :pending} = Lobbies.join(a, lobby.id)
      assert {:ok, _, :pending} = Lobbies.fetch(a, lobby.id)
      assert {:ok, :pending} = Lobbies.join(b, lobby.id)

      assert {:error, :forbidden} = Lobbies.approve(a, lobby.id, b)
      assert :ok = Lobbies.approve(host, lobby.id, a)
      assert {:ok, _, :player} = Lobbies.fetch(a, lobby.id)
      assert :ok = Lobbies.decline(host, lobby.id, b)
      assert %Member{status: "declined"} = member(lobby, b)
      assert {:error, :not_found} = Lobbies.approve(host, lobby.id, b)
    end

    test "un joueur bloqué (dans un sens ou l'autre) avec un membre ne peut pas rejoindre" do
      host = uuid()
      lobby = lobby!(host)
      member = join!(lobby, uuid())
      [blocked_by_member, blocker_of_host] = [uuid(), uuid()]
      stub_services(blocks: [{member, blocked_by_member}, {blocker_of_host, host}])

      assert {:error, :blocked} = Lobbies.join(blocked_by_member, lobby.id)
      assert {:error, :blocked} = Lobbies.join(blocker_of_host, lobby.id)
      assert {:ok, :joined} = Lobbies.join(uuid(), lobby.id)
    end

    test "social injoignable : admission refusée" do
      lobby = lobby!(uuid())
      stub_services(social: :down)
      assert {:error, :social_unavailable} = Lobbies.join(uuid(), lobby.id)
    end
  end

  describe "exclusion, départ, hôte" do
    test "l'hôte exclut un membre : banni, il ne peut ni revoir ni rejoindre ni être invité" do
      host = uuid()
      lobby = lobby!(host)
      guest = join!(lobby, uuid())

      assert {:error, :forbidden} = Lobbies.kick(guest, lobby.id, host)
      assert :ok = Lobbies.kick(host, lobby.id, guest)
      assert {:error, :banned} = Lobbies.fetch(guest, lobby.id)
      assert {:error, :banned} = Lobbies.join(guest, lobby.id)
      assert {:error, :banned} = Invitations.invite(host, lobby.id, guest)
      assert {:error, {:invalid, %{user_id: _}}} = Lobbies.kick(host, lobby.id, host)
    end

    test "l'hôte qui part est remplacé par le plus ancien membre ; le dernier départ ferme le salon" do
      host = uuid()
      lobby = lobby!(host)
      [first, second] = [join!(lobby, uuid()), join!(lobby, uuid())]

      assert :ok = Lobbies.leave(host, lobby.id)
      assert Repo.reload!(lobby).host_id == first
      assert {:ok, _, :host} = Lobbies.fetch(first, lobby.id)

      :ok = Lobbies.leave(first, lobby.id)
      :ok = Lobbies.leave(second, lobby.id)
      assert %Lobby{status: "closed"} = Repo.reload!(lobby)
      assert {:error, :not_found} = Lobbies.fetch(second, lobby.id)
      assert {:error, :forbidden} = Lobbies.leave(uuid(), lobby!(uuid()).id)
    end

    test "transfert d'hôte vers un membre actif seulement" do
      host = uuid()
      lobby = lobby!(host)
      guest = join!(lobby, uuid())

      assert {:error, :not_found} = Lobbies.transfer(host, lobby.id, uuid())
      assert {:error, :forbidden} = Lobbies.transfer(guest, lobby.id, guest)
      assert :ok = Lobbies.transfer(host, lobby.id, guest)
      assert {:ok, _, :host} = Lobbies.fetch(guest, lobby.id)
      assert {:ok, _, :player} = Lobbies.fetch(host, lobby.id)
    end

    test "prêt réservé aux membres ; démarrage par l'hôte avec au moins 2 prêts" do
      host = uuid()
      lobby = lobby!(host)
      guest = join!(lobby, uuid())

      assert {:error, :forbidden} = Lobbies.set_ready(uuid(), lobby.id, true)
      :ok = Lobbies.set_ready(host, lobby.id, true)
      assert {:error, :not_enough_ready} = Lobbies.start(host, lobby.id)
      :ok = Lobbies.set_ready(guest, lobby.id, true)
      assert {:error, :forbidden} = Lobbies.start(guest, lobby.id)
    end

    test "activité programmée : démarrage refusé avant l'heure" do
      host = uuid()
      later = DateTime.utc_now() |> DateTime.add(600)
      lobby = lobby!(host, %{"starts_at" => DateTime.to_iso8601(later)})
      guest = join!(lobby, uuid())
      for user <- [host, guest], do: :ok = Lobbies.set_ready(user, lobby.id, true)

      assert {:error, :not_yet} = Lobbies.start(host, lobby.id)
      assert Repo.reload!(lobby).status == "waiting"
    end
  end

  describe "signalement" do
    test "un membre signale un autre joueur du salon via social, en son nom" do
      host = uuid()
      lobby = lobby!(host)
      guest = join!(lobby, uuid())

      assert {:ok, _id} =
               Lobbies.report(host, lobby.id, %{
                 "user_id" => guest,
                 "reason" => "spam",
                 "details" => "ads"
               })

      assert_received {:service, "POST", "/api/reports",
                       %{
                         "target_type" => "user",
                         "target_id" => ^guest,
                         "reason" => "spam",
                         "details" => details
                       }}

      assert details =~ lobby.id and details =~ "ads"

      assert {:error, {:invalid, _}} =
               Lobbies.report(host, lobby.id, %{"user_id" => guest, "reason" => "x"})

      assert {:error, :not_found} =
               Lobbies.report(host, lobby.id, %{"user_id" => uuid(), "reason" => "spam"})

      assert {:error, :forbidden} =
               Lobbies.report(uuid(), lobby.id, %{"user_id" => guest, "reason" => "spam"})
    end
  end
end
