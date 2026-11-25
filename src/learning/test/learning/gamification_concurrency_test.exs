defmodule MlLearning.GamificationConcurrencyTest do
  @moduledoc """
  Vraie concurrence, comme `MlLearning.ConcurrencyTest` : chaque tâche a sa connexion PostgreSQL (hors bac à sable,
  données validées), nettoyées à la fin. Module synchrone : il ne tourne pas en même temps que les tests asynchrones.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias MlLearning.{Fixtures, Gamification, Progress, Repo}
  alias MlLearning.Catalog.Adventure
  alias MlLearning.Gamification.{Badge, Badges, Quest, UserBadge}
  alias MlLearning.Progress.XpEvent

  setup do
    # faux centre de notifications : les tâches de la course le trouvent par `$callers`
    Fixtures.stub_center()
    user = Fixtures.user_id()
    prefix = "race-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from e in XpEvent, where: e.user_id == ^user)
        # user_badges, chapitres, leçons, inscriptions et progression suivent (ON DELETE CASCADE)
        Repo.delete_all(from b in Badge, where: like(b.slug, ^"#{prefix}-%"))
        Repo.delete_all(from q in Quest, where: like(q.slug, ^"#{prefix}-%"))
        Repo.delete_all(from a in Adventure, where: like(a.slug, ^"#{prefix}-%"))
      end)
    end)

    %{user: user, prefix: prefix}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp in_parallel(funs) do
    funs
    |> Task.async_stream(&unboxed/1, max_concurrency: length(funs), timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp badges(prefix, n, attrs) do
    unboxed(fn ->
      for i <- 1..n, do: Fixtures.badge_fixture(Map.merge(%{slug: "#{prefix}-#{i}"}, attrs))
    end)
  end

  defp equipped(user),
    do:
      unboxed(fn ->
        Repo.all(
          from ub in UserBadge,
            where: ub.user_id == ^user and ub.equipped,
            order_by: ub.position,
            select: {ub.badge_id, ub.position}
        )
      end)

  defp earned_count(user),
    do:
      unboxed(fn ->
        Repo.aggregate(from(ub in UserBadge, where: ub.user_id == ^user), :count)
      end)

  test "16 parallel replacements: never more than 3 equipped, the result is ONE accepted list",
       %{user: user, prefix: prefix} do
    ids = badges(prefix, 10, %{criterion: "total_xp", target: 1}) |> Enum.map(& &1.id)

    unboxed(fn ->
      Fixtures.xp_event(user, "lesson:x", 5)
      Badges.award(user)
    end)

    # listes de 0 à 4 badges : celles de 4 sont refusées
    requests = for n <- 1..16, do: ids |> Enum.shuffle() |> Enum.take(rem(n, 5))
    results = in_parallel(for r <- requests, do: fn -> {r, Badges.equip(user, r)} end)

    for {request, result} <- results do
      if length(request) > 3,
        do: assert(result == {:error, :equip_limit_exceeded}),
        else: assert(result == {:ok, request})
    end

    final = equipped(user)
    accepted = for {request, {:ok, _}} <- results, do: request
    assert length(final) <= 3
    # remplacement atomique : jamais un mélange de deux demandes, positions 1..n contiguës
    assert Enum.map(final, &elem(&1, 0)) in accepted
    assert Enum.map(final, &elem(&1, 1)) == Enum.take([1, 2, 3], length(final))
  end

  test "writers bypassing equip/2 still can't equip a 4th badge: the database refuses",
       %{user: user, prefix: prefix} do
    ids = badges(prefix, 12, %{criterion: "total_xp", target: 1}) |> Enum.map(& &1.id)

    unboxed(fn ->
      Fixtures.xp_event(user, "lesson:x", 5)
      Badges.award(user)
    end)

    in_parallel(
      for {id, i} <- Enum.with_index(ids) do
        fn ->
          row = from(ub in UserBadge, where: ub.user_id == ^user and ub.badge_id == ^id)

          try do
            Repo.update_all(row, set: [equipped: true, position: rem(i, 4) + 1])
          rescue
            Postgrex.Error -> :refused
          end
        end
      end
    )

    final = equipped(user)
    assert length(final) <= 3
    assert final |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == length(final)
  end

  test "12 parallel evaluations: each badge is earned exactly once", %{user: user, prefix: prefix} do
    [small, big] =
      unboxed(fn ->
        [
          Fixtures.badge_fixture(slug: "#{prefix}-1", criterion: "total_xp", target: 10),
          Fixtures.badge_fixture(slug: "#{prefix}-2", criterion: "total_xp", target: 20)
        ]
      end)

    unboxed(fn -> Fixtures.xp_event(user, "lesson:x", 30) end)

    awarded = in_parallel(for _ <- 1..12, do: fn -> Badges.award(user) end)

    assert awarded |> List.flatten() |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([small.id, big.id])

    assert earned_count(user) == 2
  end

  test "lessons completed at the same time that reach a threshold together still earn the badge",
       %{user: user, prefix: prefix} do
    [badge] = badges(prefix, 1, %{criterion: "total_xp", target: 50})

    # 6 leçons de 10 XP, 5 terminées en parallèle : 50 XP, aventure non finie (pas de bonus)
    lessons =
      unboxed(fn ->
        Fixtures.adventure_fixture(%{slug: "#{prefix}-adventure"}, [
          for(_ <- 1..6, do: %{xp_reward: 10})
        ])
        |> Fixtures.lessons_of()
      end)

    results =
      in_parallel(for l <- Enum.take(lessons, 5), do: fn -> Progress.complete(user, l) end)

    assert Enum.all?(results, &(&1 == {:ok, :awarded}))
    assert unboxed(fn -> Progress.xp_stats(user).xp end) == 50

    assert unboxed(fn -> Repo.all(from ub in UserBadge, where: ub.user_id == ^user) end)
           |> Enum.map(& &1.badge_id) == [badge.id]
  end

  test "12 parallel settlements reward a daily quest once", %{user: user, prefix: prefix} do
    quest =
      unboxed(fn ->
        Fixtures.quest_fixture(slug: "#{prefix}-xp", kind: "xp_earned", target: 30, xp_reward: 20)
      end)

    unboxed(fn -> Fixtures.xp_event(user, "lesson:x", 40) end)

    statuses = in_parallel(for _ <- 1..12, do: fn -> Gamification.settle_quests(user) end)

    assert Enum.all?(statuses, &match?([%{completed: true}], &1))
    key = "quest:#{quest.id}:#{Date.to_iso8601(Date.utc_today())}"

    assert unboxed(fn ->
             Repo.all(
               from e in XpEvent,
                 where: e.user_id == ^user and like(e.ref_key, "quest:%"),
                 select: {e.ref_key, e.amount}
             )
           end) == [{key, 20}]
  end
end
