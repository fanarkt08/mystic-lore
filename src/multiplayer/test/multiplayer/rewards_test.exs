defmodule MlMultiplayer.RewardsTest do
  use MlMultiplayer.DataCase, async: false
  alias MlMultiplayer.{Lobbies, MatchServer, Reward, Rewards}

  # les échecs de livraison sont journalisés (sans données) : capturés ici
  @moduletag :capture_log

  defp win!(count \\ 2) do
    %{lobby: lobby, match: match, players: players} = playing!(count)
    state = engine(match.id)
    {:ok, %{"status" => "won"}} = Lobbies.attempt(hd(state.players), lobby.id, state.secret)
    %{lobby: lobby, match: match, players: players, order: state.players}
  end

  defp xp_calls do
    receive do
      {:service, "POST", "/api/internal/xp", body} -> [body | xp_calls()]
      {:service, _, _, _} -> xp_calls()
    after
      0 -> []
    end
  end

  test "victoire : 50 XP une seule fois pour chaque participant présent à la fin" do
    %{lobby: lobby, match: match, order: [first, second, absent]} = win_with_absent!()

    assert Repo.all(from r in Reward, where: r.match_id == ^match.id, select: r.user_id)
           |> Enum.sort() ==
             Enum.sort([first, second])

    xp_calls()
    assert ["awarded", "awarded"] = Rewards.deliver_due()
    ref = "multiplayer:match:#{match.id}"

    assert xp_calls() |> Enum.sort_by(& &1["user_id"]) ==
             for(
               user <- Enum.sort([first, second]),
               do: %{"user_id" => user, "ref_key" => ref, "amount" => 50}
             )

    assert Rewards.deliver_due() == []
    assert xp_calls() == []
    assert {:ok, 0} = Rewards.finalize(match.id)

    assert {:ok, %{match: %{"my_reward" => %{"status" => "awarded"}}}} =
             Lobbies.detail(first, lobby.id)

    assert {:ok, %{match: %{"my_reward" => nil}}} = Lobbies.detail(absent, lobby.id)
  end

  defp win_with_absent! do
    %{lobby: lobby, match: match} = playing!(3)
    [first, second, third] = engine(match.id).players
    :ok = MatchServer.set_absent(match.id, third, true)
    state = engine(match.id)
    {:ok, _} = Lobbies.attempt(first, lobby.id, wrong_guess(state.secret))
    {:ok, %{"status" => "won"}} = Lobbies.attempt(second, lobby.id, state.secret)
    %{lobby: lobby, match: match, order: [first, second, third]}
  end

  test "learning injoignable : la récompense reste en attente, puis est rattrapée" do
    %{match: match} = win!()
    stub_services(learning: :down)
    now = DateTime.utc_now()

    assert ["pending", "pending"] = Rewards.deliver_due(now)
    rewards = Repo.all(from r in Reward, where: r.match_id == ^match.id)
    assert Enum.all?(rewards, &(&1.status == "pending" and &1.attempts == 1))
    assert Enum.all?(rewards, &(&1.last_error == "learning unavailable"))
    assert Enum.all?(rewards, &(DateTime.diff(&1.next_attempt_at, now) == 5))

    # pas de relance avant l'échéance (backoff)
    xp_calls()
    assert Rewards.deliver_due(DateTime.add(now, 2)) == []
    assert xp_calls() == []

    assert ["pending", "pending"] = Rewards.deliver_due(DateTime.add(now, 5))
    assert Enum.all?(Repo.all(Reward), &(DateTime.diff(&1.next_attempt_at, now) == 15))
    assert length(xp_calls()) == 2

    stub_services()
    assert ["awarded", "awarded"] = Rewards.deliver_due(DateTime.add(now, 15))
    assert length(xp_calls()) == 2

    assert Enum.all?(
             Repo.all(Reward),
             &(&1.status == "awarded" and &1.attempts == 3 and &1.last_error == nil)
           )
  end

  test "refus définitif de learning (422) : récompense marquée en échec, jamais perdue en silence" do
    %{match: match, players: [host | _]} = win!()
    stub_services(learning: {:status, 422})
    assert ["failed", "failed"] = Rewards.deliver_due()
    assert Enum.all?(Repo.all(Reward), &(&1.status == "failed"))
    assert Rewards.deliver_due() == []

    {:ok, detail} = Lobbies.detail(host, Repo.get!(MlMultiplayer.Match, match.id).lobby_id)
    assert detail.match["my_reward"] == %{"amount" => 50, "status" => "failed"}
  end

  test "défaite ou interruption : aucune récompense" do
    %{lobby: lobby, match: match} = playing!(2)
    :ok = MatchServer.abort(match.id, "not_enough_players")
    assert {:ok, 0} = Rewards.finalize(match.id)
    assert Repo.aggregate(Reward, :count) == 0

    assert {:ok, %{match: %{"status" => "aborted"}}} =
             Lobbies.detail(hd(Lobbies.active_ids(lobby.id)), lobby.id)
  end
end
