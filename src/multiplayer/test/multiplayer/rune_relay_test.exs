defmodule MlMultiplayer.RuneRelayTest do
  use ExUnit.Case, async: true
  alias MlMultiplayer.RuneRelay, as: Engine

  @players ["p1", "p2", "p3"]

  defp start(seed \\ 42, players \\ @players), do: Engine.init(Engine.start_event(seed, players))

  defp play(state, user, guess) do
    {:ok, events} = Engine.decide(state, user, {:propose, guess})
    Enum.reduce(events, state, &Engine.apply_event(&2, &1))
  end

  defp wrong(secret), do: tl(secret) ++ [hd(secret)]

  test "déterministe : même graine et mêmes joueurs ⇒ même partie ; autre graine ⇒ autre partie" do
    assert Engine.start_event(7, @players) == Engine.start_event(7, @players)

    refute Engine.start_event(7, @players)["payload"]["secret"] ==
             Engine.start_event(8, @players)["payload"]["secret"]
  end

  test "le secret : 5 runes distinctes parmi 8, ordre de jeu = les joueurs" do
    for seed <- 1..30 do
      %{"secret" => secret, "players" => order} = Engine.start_event(seed, @players)["payload"]
      assert length(secret) == 5 and length(Enum.uniq(secret)) == 5
      assert Enum.all?(secret, &(&1 in 0..7))
      assert Enum.sort(order) == Enum.sort(@players)
    end
  end

  test "indices : tous vrais, chaque joueur en a, et ensemble ils n'admettent qu'une solution" do
    candidates = Engine.candidates()
    assert length(candidates) == 6720

    for seed <- 1..25, players <- [["a", "b"], @players, ["a", "b", "c", "d"]] do
      %{"secret" => secret, "hints" => hints} = Engine.start_event(seed, players)["payload"]
      assert Enum.sort(Map.keys(hints)) == Enum.sort(players)
      assert Enum.all?(hints, fn {_player, own} -> own != [] end)

      all = hints |> Map.values() |> List.flatten()
      assert Enum.all?(all, &Engine.holds?(&1, secret))

      assert [^secret] =
               Enum.filter(candidates, fn c -> Enum.all?(all, &Engine.holds?(&1, c)) end)
    end
  end

  test "coopération nécessaire : les indices d'un seul joueur ne suffisent pas en général" do
    solo =
      for seed <- 1..25 do
        %{"hints" => hints} = Engine.start_event(seed, ["a", "b"])["payload"]

        Enum.count(Engine.candidates(), fn c -> Enum.all?(hints["a"], &Engine.holds?(&1, c)) end)
      end

    assert Enum.all?(solo, &(&1 > 1))
  end

  test "indices privés : chaque vue ne contient que les indices de son joueur, jamais le secret en cours" do
    state = start()

    for player <- @players do
      view = Engine.view(state, player)
      assert view["my_hints"] == state.hints[player]
      assert view["secret"] == nil
      refute Map.has_key?(view, "hints")

      for other <- @players -- [player], hint <- state.hints[other] -- state.hints[player] do
        refute hint in view["my_hints"]
      end
    end

    assert Engine.view(state, "spectator")["my_hints"] == []
  end

  test "validation des intentions : tour, participant, forme, doublons, intention inconnue" do
    state = start()
    first = Engine.current_player(state)
    other = Enum.find(@players, &(&1 != first))
    guess = wrong(state.secret)

    assert {:error, :not_your_turn} = Engine.decide(state, other, {:propose, guess})
    assert {:error, :not_participant} = Engine.decide(state, "intruder", {:propose, guess})
    assert {:error, :invalid_sequence} = Engine.decide(state, first, {:propose, [0, 1, 2]})
    assert {:error, :invalid_sequence} = Engine.decide(state, first, {:propose, [0, 1, 2, 3, 8]})

    assert {:error, :invalid_sequence} =
             Engine.decide(state, first, {:propose, ["0", 1, 2, 3, 4]})

    assert {:error, :invalid_sequence} = Engine.decide(state, first, {:propose, "01234"})
    assert {:error, :duplicate_runes} = Engine.decide(state, first, {:propose, [0, 0, 1, 2, 3]})
    assert {:error, :invalid_intent} = Engine.decide(state, first, {:win, true})
  end

  test "une tentative est notée par le serveur et passe le trait au joueur suivant" do
    state = start()
    first = Engine.current_player(state)
    guess = wrong(state.secret)
    after_first = play(state, first, guess)

    assert [%{"user_id" => ^first, "n" => 1, "sequence" => ^guess, "marks" => marks}] =
             after_first.attempts

    assert marks == Engine.score(state.secret, guess)
    assert Enum.all?(marks, &(&1 == "present"))
    assert Engine.current_player(after_first) == Enum.at(state.players, 1)
    assert Engine.score([0, 1, 2, 3, 4], [0, 2, 1, 7, 6]) == ~w(hit present present miss miss)
  end

  test "victoire coopérative ; défaite après 6 tentatives ; secret révélé à la fin seulement" do
    state = start()
    won = play(state, Engine.current_player(state), state.secret)
    assert won.status == "won"
    assert Engine.view(won, "p1")["secret"] == state.secret
    assert {:error, :finished} = Engine.decide(won, "p1", {:propose, state.secret})

    lost =
      Enum.reduce(1..6, state, fn _, s ->
        play(s, Engine.current_player(s), wrong(state.secret))
      end)

    assert lost.status == "lost"
    assert Engine.view(lost, "p2")["attempts_left"] == 0
    assert Engine.view(lost, "p2")["secret"] == state.secret
  end

  test "rejeu du journal (après aller-retour JSON) : état identique" do
    start_event = Engine.start_event(5, @players)
    state = Engine.init(start_event)

    {:ok, e1} =
      Engine.decide(state, Engine.current_player(state), {:propose, wrong(state.secret)})

    s1 = Enum.reduce(e1, state, &Engine.apply_event(&2, &1))
    {:ok, e2} = Engine.decide(s1, Enum.at(s1.players, 1), {:absent, true})
    s2 = Enum.reduce(e2, s1, &Engine.apply_event(&2, &1))
    {:ok, e3} = Engine.decide(s2, Engine.current_player(s2), {:propose, state.secret})
    s3 = Enum.reduce(e3, s2, &Engine.apply_event(&2, &1))

    journal = [start_event | e1 ++ e2 ++ e3] |> Jason.encode!() |> Jason.decode!()
    assert Engine.replay(journal) == s3
    assert s3.status == "won"
  end

  test "un joueur absent est sauté, puis réintégré à son retour" do
    state = start()
    [a, b, c] = state.players
    assert Engine.current_player(state) == a

    {:ok, [absence]} = Engine.decide(state, b, {:absent, true})
    state = Engine.apply_event(state, absence)
    assert {:ok, []} = Engine.decide(state, b, {:absent, true})

    state = play(state, a, wrong(state.secret))
    assert Engine.current_player(state) == c

    # le joueur au trait s'absente : le trait passe aussitôt au suivant présent
    {:ok, [absence]} = Engine.decide(state, c, {:absent, true})
    state = Engine.apply_event(state, absence)
    assert Engine.current_player(state) == a

    {:ok, [back]} = Engine.decide(state, b, {:absent, false})
    state = Engine.apply_event(state, back)
    state = play(state, a, wrong(state.secret))
    assert Engine.current_player(state) == b
    assert state.absent == [c]
  end

  test "interruption par le serveur" do
    {:ok, [event]} = Engine.decide(start(), nil, {:abort, "not_enough_players"})
    state = Engine.apply_event(start(), event)
    assert {state.status, state.reason} == {"aborted", "not_enough_players"}
    assert Engine.view(state, "p1")["secret"]
  end
end
