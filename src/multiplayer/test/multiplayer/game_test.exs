defmodule MlMultiplayer.GameTest do
  # Le MatchServer est un autre processus : sandbox partagée.
  use MlMultiplayer.DataCase, async: false
  alias MlMultiplayer.{Lobbies, Match, MatchEvent, MatchServer, Matches, Member, Presence}

  defp view(user, lobby) do
    {:ok, detail} = Lobbies.detail(user, lobby.id)
    detail.match
  end

  defp collect(acc \\ []) do
    receive do
      {:service, _, _, _} -> collect(acc)
      message -> collect([message | acc])
    after
      0 -> acc
    end
  end

  defp seen(lobby, user, at),
    do:
      Repo.update_all(from(m in Member, where: m.lobby_id == ^lobby.id and m.user_id == ^user),
        set: [last_seen_at: at]
      )

  test "démarrage : seuls les membres prêts jouent ; le salon passe en partie ; journal initial" do
    host = uuid()
    lobby = lobby!(host)
    [ready, idle] = [join!(lobby, uuid()), join!(lobby, uuid())]
    for user <- [host, ready], do: :ok = Lobbies.set_ready(user, lobby.id, true)
    MlShared.Events.subscribe("lobby:#{lobby.id}")

    assert {:ok, %Match{status: "active"} = match} = Lobbies.start(host, lobby.id)
    lobby_id = lobby.id
    assert_receive {:lobby_changed, ^lobby_id}
    assert %{status: "playing", current_match_id: match_id} = Repo.reload!(lobby)
    assert match_id == match.id
    assert {:error, :in_progress} = Lobbies.start(host, lobby.id)
    assert {:error, :in_progress} = Lobbies.set_ready(idle, lobby.id, false)

    assert [%MatchEvent{seq: 1, type: "match_started"}] = Repo.all(MatchEvent)
    assert Enum.sort(engine(match.id).players) == Enum.sort([host, ready])
    assert view(idle, lobby)["my_hints"] == []
  end

  test "indices privés : chaque joueur reçoit ses indices seulement ; secret jamais exposé en cours" do
    %{lobby: lobby, match: match, players: players} = playing!(3)
    state = engine(match.id)

    for player <- players do
      match_view = view(player, lobby)
      assert match_view["my_hints"] == state.hints[player]
      assert match_view["secret"] == nil
      refute Map.has_key?(match_view, "hints")
    end

    assert view(uuid(), lobby)["my_hints"] == []
  end

  test "tentatives validées côté serveur, diffusion sans indice ni secret, victoire" do
    %{lobby: lobby, match: match} = playing!(2)
    state = engine(match.id)
    [first, second] = state.players
    lobby_id = lobby.id
    MlShared.Events.subscribe("lobby:#{lobby.id}")

    assert {:error, :not_your_turn} = Lobbies.attempt(second, lobby.id, state.secret)
    assert {:error, :duplicate_runes} = Lobbies.attempt(first, lobby.id, [1, 1, 2, 3, 4])
    assert {:error, :forbidden} = Lobbies.attempt(uuid(), lobby.id, state.secret)

    assert {:ok, %{"attempts" => [%{"marks" => marks}], "current_player" => ^second}} =
             Lobbies.attempt(first, lobby.id, wrong_guess(state.secret))

    assert marks == List.duplicate("present", 5)

    assert {:ok, %{"status" => "won", "secret" => secret}} =
             Lobbies.attempt(second, lobby.id, state.secret)

    assert secret == state.secret

    # tout ce qui a été diffusé sur "lobby:<id>" : de simples notifications, sans aucune donnée de partie
    broadcasts = collect()
    assert length(broadcasts) == 2 and Enum.all?(broadcasts, &(&1 == {:lobby_changed, lobby_id}))

    assert %{status: "waiting"} = Repo.reload!(lobby)

    assert Repo.all(from m in Member, where: m.lobby_id == ^lobby.id, select: m.ready) == [
             false,
             false
           ]

    assert %Match{status: "won", last_seq: 4, finished_at: %DateTime{}} =
             Repo.get!(Match, match.id)

    assert {:error, :no_match} = Lobbies.attempt(first, lobby.id, state.secret)
    assert view(first, lobby)["my_reward"] == %{"amount" => 50, "status" => "pending"}
  end

  test "reconstruction : après l'arrêt du GenServer, l'état est rejoué depuis match_events" do
    %{lobby: lobby, match: match} = playing!(3)
    state = engine(match.id)
    [first, second, _] = state.players
    {:ok, _} = Lobbies.attempt(first, lobby.id, wrong_guess(state.secret))
    :ok = MatchServer.set_absent(match.id, second, true)
    before = engine(match.id)

    pid = MatchServer.whereis(match.id)
    stop_server(match.id)
    refute MatchServer.whereis(match.id)

    assert engine(match.id) == before
    refute MatchServer.whereis(match.id) == pid
    assert {:ok, rebuilt, 3} = Matches.replay(match.id)
    assert rebuilt == before

    assert Repo.all(
             from e in MatchEvent, where: e.match_id == ^match.id, select: e.seq, order_by: e.seq
           ) ==
             [1, 2, 3]
  end

  test "écriture concurrente du journal détectée (séquence) : la partie est rechargée, rien n'est perdu" do
    %{lobby: lobby, match: match} = playing!(2)
    state = engine(match.id)
    [first, _second] = state.players

    # un autre écrivain a avancé le journal sans passer par ce processus
    {:ok, events} =
      MlMultiplayer.RuneRelay.decide(state, first, {:propose, wrong_guess(state.secret)})

    advanced = Enum.reduce(events, state, &MlMultiplayer.RuneRelay.apply_event(&2, &1))
    {:ok, _} = Matches.commit(match.id, 1, events, advanced)

    assert {:error, :conflict} = Lobbies.attempt(first, lobby.id, wrong_guess(state.secret))
    assert engine(match.id) == advanced
    assert {:error, :conflict} = Matches.commit(match.id, 1, events, advanced)
  end

  describe "connexion par battements" do
    test "30 s sans battement → déconnecté ; 60 s de grâce → absent et sauté ; retour → réintégré" do
      %{lobby: lobby, match: match, players: players} = playing!(3)
      [first, second, third] = engine(match.id).players
      now = DateTime.utc_now()
      for user <- players, do: :ok = Presence.heartbeat(user, lobby.id, now)

      seen(lobby, second, DateTime.add(now, -31))
      :ok = Presence.sweep(now)

      assert Repo.get_by!(Member, lobby_id: lobby.id, user_id: second).connection ==
               "disconnected"

      assert engine(match.id).absent == []

      seen(lobby, second, DateTime.add(now, -91))
      :ok = Presence.sweep(now)
      assert Repo.get_by!(Member, lobby_id: lobby.id, user_id: second).connection == "absent"
      assert engine(match.id).absent == [second]

      state = engine(match.id)

      {:ok, %{"current_player" => ^third}} =
        Lobbies.attempt(first, lobby.id, wrong_guess(state.secret))

      # retour : battement → online, réintégré, état exact relu depuis la base
      :ok = Presence.heartbeat(second, lobby.id, now)
      assert engine(match.id).absent == []
      assert %{"attempts" => [_], "current_player" => ^third} = view(second, lobby)

      {:ok, %{"current_player" => ^first}} =
        Lobbies.attempt(third, lobby.id, wrong_guess(state.secret))
    end

    test "battement réservé aux membres actifs" do
      lobby = lobby!(uuid())
      assert {:error, :forbidden} = Presence.heartbeat(uuid(), lobby.id)

      assert {:error, :not_found} =
               Presence.heartbeat(uuid(), lobby!(uuid(), %{"visibility" => "private"}).id)
    end

    test "un départ pendant la partie : le joueur est sauté ; moins de 2 joueurs → partie interrompue" do
      %{lobby: lobby, match: match, players: [host, leaver, kicked]} = playing!(3)

      :ok = Lobbies.leave(leaver, lobby.id)
      assert engine(match.id).absent == [leaver]
      assert engine(match.id).status == "active"

      :ok = Lobbies.kick(host, lobby.id, kicked)
      assert %Match{status: "aborted"} = Repo.get!(Match, match.id)
      assert %{status: "waiting"} = Repo.reload!(lobby)
      assert %{"status" => "aborted", "reason" => "not_enough_players"} = view(host, lobby)
    end

    test "tous absents depuis 10 minutes → partie abandonnée (secret révélé)" do
      %{lobby: lobby, match: match, players: [host | _]} = playing!(2)
      now = DateTime.utc_now()

      Repo.update_all(from(m in Member, where: m.lobby_id == ^lobby.id),
        set: [last_seen_at: DateTime.add(now, -601)]
      )

      :ok = Presence.sweep(now)
      assert %Match{status: "aborted"} = Repo.get!(Match, match.id)

      assert %{"status" => "aborted", "reason" => "abandoned", "secret" => [_, _, _, _, _]} =
               view(host, lobby)
    end
  end
end
