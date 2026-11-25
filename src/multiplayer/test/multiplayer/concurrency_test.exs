defmodule MlMultiplayer.ConcurrencyTest do
  @moduledoc """
  Courses réelles : chaque opération tourne hors sandbox, sur sa propre connexion et dans sa propre transaction
  validée. Les membres sont des UUID aléatoires ; leurs salons (et tout ce qui en dépend) sont supprimés à la fin.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  import MlMultiplayer.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  alias MlMultiplayer.{
    Chat,
    Invitations,
    Lobbies,
    Lobby,
    Match,
    MatchEvent,
    Matches,
    Member,
    Repo,
    Reward,
    Rewards,
    RuneRelay
  }

  setup do
    stub_services()
    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Hôte de test dont les salons (membres, messages, parties, récompenses en cascade) sont supprimés à la fin.
  defp host! do
    id = uuid()

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from l in Lobby, where: l.host_id == ^id) end)
    end)

    id
  end

  defp concurrently(funs) do
    funs
    |> Task.async_stream(&unboxed/1, max_concurrency: 12, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "capacité : 10 arrivées simultanées pour 3 places libres → exactement 4 membres" do
    host = host!()
    lobby = unboxed(fn -> lobby!(host, %{"max_players" => 4}) end)
    results = concurrently(for _ <- 1..10, do: fn -> Lobbies.join(uuid(), lobby.id) end)

    assert Enum.count(results, &(&1 == {:ok, :joined})) == 3
    assert Enum.count(results, &(&1 == {:error, :full})) == 7

    assert unboxed(fn ->
             Repo.aggregate(
               from(m in Member, where: m.lobby_id == ^lobby.id and m.status == "active"),
               :count
             )
           end) == 4
  end

  test "lien à usage unique : un seul des 6 joueurs simultanés entre" do
    host = host!()

    {lobby, token} =
      unboxed(fn ->
        lobby = lobby!(host, %{"visibility" => "private"})
        {:ok, _link, token} = Invitations.create_link(host, lobby.id, %{"max_uses" => 1})
        {lobby, token}
      end)

    results = concurrently(for _ <- 1..6, do: fn -> Invitations.join_link(uuid(), token) end)
    assert Enum.count(results, &(&1 == {:ok, lobby.id})) == 1
    assert Enum.count(results, &(&1 == {:error, :exhausted})) == 5
  end

  test "limite de salons par hôte tenue en concurrence" do
    host = host!()
    attrs = %{"title" => "Race", "visibility" => "open", "max_players" => 2}
    results = concurrently(for _ <- 1..6, do: fn -> Lobbies.create(host, attrs) end)

    assert Enum.count(results, &match?({:ok, %Lobby{}}, &1)) == 3
    assert Enum.count(results, &(&1 == {:error, :too_many_lobbies})) == 3
  end

  test "chat : 10 envois simultanés → 5 acceptés, 5 limités" do
    host = host!()
    lobby = unboxed(fn -> lobby!(host) end)

    results =
      concurrently(for i <- 1..10, do: fn -> Chat.post(host, lobby.id, %{"body" => "m#{i}"}) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 5
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 5
  end

  test "récompense : finalisations et livraisons simultanées → une ligne et un envoi par joueur" do
    host = host!()
    guest = uuid()

    match =
      unboxed(fn ->
        lobby = lobby!(host)
        join!(lobby, guest)
        for user <- [host, guest], do: :ok = Lobbies.set_ready(user, lobby.id, true)
        {:ok, match} = Lobbies.start(host, lobby.id)
        win_without_rewards(match)
        match
      end)

    created = concurrently(for _ <- 1..10, do: fn -> Rewards.finalize(match.id) end)
    assert Enum.sum(for {:ok, n} <- created, do: n) == 2

    flush()
    now = DateTime.utc_now()
    delivered = concurrently(for _ <- 1..10, do: fn -> Rewards.deliver_due(now) end)
    assert delivered |> List.flatten() |> Enum.sort() == ["awarded", "awarded"]

    calls = flush()
    assert Enum.sort(for(%{"user_id" => id} <- calls, do: id)) == Enum.sort([host, guest])
    assert Enum.all?(calls, &(&1["ref_key"] == "multiplayer:match:#{match.id}"))

    assert unboxed(fn ->
             Repo.all(from r in Reward, where: r.match_id == ^match.id, select: r.status)
           end) == ["awarded", "awarded"]
  end

  # Victoire écrite directement dans le journal, sans passer par la finalisation (qui est mise en course ici).
  defp win_without_rewards(match) do
    {:ok, state, 1} = Matches.replay(match.id)

    {:ok, events} =
      RuneRelay.decide(state, RuneRelay.current_player(state), {:propose, state.secret})

    Repo.insert_all(
      MatchEvent,
      for {event, seq} <- Enum.with_index(events, 2) do
        %{
          match_id: match.id,
          seq: seq,
          type: event["type"],
          user_id: event["user_id"],
          payload: event["payload"],
          inserted_at: DateTime.utc_now()
        }
      end
    )

    Repo.update_all(from(m in Match, where: m.id == ^match.id), set: [status: "won", last_seq: 3])
  end

  defp flush(acc \\ []) do
    receive do
      {:service, "POST", "/api/internal/xp", body} -> flush([body | acc])
      {:service, _, _, _} -> flush(acc)
    after
      0 -> acc
    end
  end
end
