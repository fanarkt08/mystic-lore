defmodule MlLearning.GamificationTest do
  use MlLearning.DataCase, async: true
  alias MlLearning.{Gamification, Progress}
  alias MlLearning.Gamification.{Badges, UserBadge}
  alias MlLearning.Progress.{LessonProgress, XpEvent}

  # Slugs uniques (fixtures) : jamais ceux des seeds, que le test des seeds insère en parallèle.
  defp earned(user),
    do:
      Repo.all(from ub in UserBadge, where: ub.user_id == ^user, select: ub.badge_id)
      |> MapSet.new()

  defp ids(badges), do: MapSet.new(badges, & &1.id)

  defp positions(user),
    do:
      Repo.all(
        from ub in UserBadge,
          where: ub.user_id == ^user and ub.equipped,
          order_by: ub.position,
          select: {ub.badge_id, ub.position}
      )

  defp quest_rewards(user),
    do:
      Repo.all(
        from e in XpEvent,
          where: e.user_id == ^user and like(e.ref_key, "quest:%"),
          order_by: e.ref_key,
          select: {e.ref_key, e.amount}
      )

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(:second), -n * 86_400)

  describe "badge criteria, evaluated on real data" do
    test "first lesson, Le bosquet des boucles and a finished adventure: earned by the progress itself" do
      user = user_id()
      first = badge_fixture(criterion: "lessons_completed", target: 1)

      grove =
        badge_fixture(criterion: "lesson_completed", param: "Le bosquet des boucles", target: 1)

      trail = badge_fixture(criterion: "adventures_completed", target: 1)
      [story, code] = adventure_fixture(%{}, [[%{}], [coding()]]) |> lessons_of()

      assert {:ok, :awarded} = Progress.complete(user, story)
      assert earned(user) == ids([first])

      assert {:ok, :none} = Progress.submit(user, code, false)
      assert earned(user) == ids([first])

      assert {:ok, :awarded} = Progress.submit(user, code, true)
      assert earned(user) == ids([first, grove, trail])
    end

    test "every badge earned is notified once to the notification center (key badge:<slug>)" do
      user = user_id()
      first = badge_fixture(criterion: "lessons_completed", target: 1)
      [story] = adventure_fixture(%{}, [[%{}]]) |> lessons_of()

      assert {:ok, :awarded} = Progress.complete(user, story)
      key = "badge:#{first.slug}"

      assert_received {:center,
                       %{
                         "user_id" => ^user,
                         "category" => "learning",
                         "kind" => "badge_earned",
                         "params" => %{"badge_slug" => slug, "badge_name" => name},
                         "dedupe_key" => ^key
                       }}

      assert {slug, name} == {first.slug, first.name}
      refute_received {:center, %{"user_id" => ^user}}

      # evaluating again earns nothing new: nothing notified
      assert [] = Badges.award(user)
      refute_received {:center, _}
    end

    @tag :capture_log
    test "the center unreachable never prevents the badge" do
      user = user_id()
      first = badge_fixture(criterion: "lessons_completed", target: 1)
      [story] = adventure_fixture(%{}, [[%{}]]) |> lessons_of()
      Req.Test.stub(MlShared.Client, &Req.Test.transport_error(&1, :econnrefused))
      assert {:ok, :awarded} = Progress.complete(user, story)
      assert earned(user) == ids([first])
    end

    test "XP, level, streak of consecutive UTC days and multiplayer victories" do
      user = user_id()
      xp100 = badge_fixture(criterion: "total_xp", target: 100)
      level3 = badge_fixture(criterion: "level", target: 3)
      streak3 = badge_fixture(criterion: "streak_days", target: 3)
      duel = badge_fixture(criterion: "multiplayer_wins", target: 1)

      xp_event(user, "lesson:a", 60, days_ago(2))
      xp_event(user, "lesson:b", 30, days_ago(1))
      # 90 XP, niveau 1, série de 2 jours, aucune victoire
      assert Badges.award(user) == []

      xp_event(user, "lesson:c", 20)
      assert user |> Badges.award() |> ids() == ids([xp100, streak3])

      # une clé `multiplayer:…` = une victoire ; 310 XP = niveau 3
      xp_event(user, "multiplayer:match:7", 200)
      assert user |> Badges.award() |> ids() == ids([level3, duel])
      assert earned(user) == ids([xp100, streak3, level3, duel])
    end

    test "awarding is idempotent and an earned badge is kept" do
      user = user_id()
      badge = badge_fixture(criterion: "streak_days", target: 1)
      xp_event(user, "lesson:a", 10)

      assert [%{id: id}] = Badges.award(user)
      assert id == badge.id
      assert Badges.award(user) == []
      # la série retombe à zéro dans deux jours : le badge reste acquis
      assert Badges.award(user, Date.add(Date.utc_today(), 2)) == []
      assert Repo.aggregate(from(ub in UserBadge, where: ub.user_id == ^user), :count) == 1
    end

    test "achievements: earned and locked badges, progress towards the criterion (capped)" do
      user = user_id()
      hundred = badge_fixture(criterion: "total_xp", target: 100, position: 1)
      five_hundred = badge_fixture(criterion: "total_xp", target: 500, position: 2)
      week = badge_fixture(criterion: "streak_days", target: 7, position: 3)
      xp_event(user, "lesson:a", 155)
      Badges.award(user)

      assert %{badges: [a, b, c], equipped: []} = Badges.achievements(user)
      assert {a.badge.id, a.current, a.user_badge.equipped} == {hundred.id, 100, false}
      assert {b.badge.id, b.current, b.user_badge} == {five_hundred.id, 155, nil}
      assert {c.badge.id, c.current, c.user_badge} == {week.id, 1, nil}
    end
  end

  describe "equipping" do
    setup do
      user = user_id()
      xp_event(user, "lesson:a", 10)
      badges = for _ <- 1..4, do: badge_fixture(criterion: "total_xp", target: 1)
      locked = badge_fixture(criterion: "total_xp", target: 1_000)
      Badges.award(user)
      %{user: user, ids: Enum.map(badges, & &1.id), locked: locked}
    end

    test "replaces the equipped list atomically and in order (equip, reorder, unequip)",
         %{user: user, ids: [a, b, c, d]} do
      assert {:ok, [b, a]} == Badges.equip(user, [b, a])
      assert positions(user) == [{b, 1}, {a, 2}]

      assert {:ok, _} = Badges.equip(user, [b, a, c])
      assert {:ok, _} = Badges.equip(user, [c, b, a])
      assert positions(user) == [{c, 1}, {b, 2}, {a, 3}]

      assert {:ok, _} = Badges.equip(user, [c, a])
      assert positions(user) == [{c, 1}, {a, 2}]

      assert {:ok, _} = Badges.equip(user, [d])
      assert positions(user) == [{d, 1}]
      assert {:ok, []} == Badges.equip(user, [])
      assert positions(user) == []

      {:ok, _} = Badges.equip(user, [a])
      assert [{%{id: ^a}, 1}] = Badges.equipped(user)
    end

    test "never more than 3, never a badge that isn't earned, never malformed ids",
         %{user: user, ids: [a, b, c, d], locked: locked} do
      {:ok, _} = Badges.equip(user, [a, b])

      assert Badges.equip(user, [a, b, c, d]) == {:error, :equip_limit_exceeded}
      assert Badges.equip(user, [a, locked.id]) == {:error, :badge_not_earned}
      assert Badges.equip(user, [Ecto.UUID.generate()]) == {:error, :badge_not_earned}

      for bad <- [[a, a], ["nope"], [1], a, nil, %{"0" => a}] do
        assert {:error, {:invalid, %{badge_ids: [_]}}} = Badges.equip(user, bad)
      end

      # gagné par un autre membre seulement : refusé chez moi (l'attribution suit une progression, pas une lecture)
      other = user_id()
      theirs = badge_fixture(criterion: "total_xp", target: 1)
      xp_event(other, "lesson:z", 10)
      assert MapSet.member?(ids(Badges.award(other)), theirs.id)
      assert Badges.equip(user, [theirs.id]) == {:error, :badge_not_earned}

      # les refus ne modifient rien
      assert positions(user) == [{a, 1}, {b, 2}]
    end

    test "the database itself refuses a 4th slot, a shared slot or an equipped badge without slot",
         %{user: user, ids: [a, b, c, d]} do
      {:ok, _} = Badges.equip(user, [a, b, c])
      row = from(ub in UserBadge, where: ub.user_id == ^user and ub.badge_id == ^d)

      for set <- [[equipped: true, position: 4], [equipped: true, position: 1], [equipped: true]] do
        assert_raise Postgrex.Error, fn ->
          Repo.transact(fn -> {:ok, Repo.update_all(row, set: set)} end)
        end
      end

      assert positions(user) == [{a, 1}, {b, 2}, {c, 3}]
    end
  end

  describe "daily quests" do
    setup do
      user = user_id()
      # d n'est jamais terminée : l'aventure ne se finit pas (pas de bonus de 50 XP)
      [a, b, c, d] =
        adventure_fixture(%{}, [
          [%{xp_reward: 10}, %{xp_reward: 15}, %{xp_reward: 10}, quiz()]
        ])
        |> lessons_of()

      %{user: user, a: a, b: b, c: c, d: d}
    end

    test "progress of the UTC day, one reward per quest, quest XP excluded from the XP quest",
         %{user: user, a: a, b: b, c: c, d: d} do
      lessons = quest_fixture(kind: "lessons_completed", target: 2, xp_reward: 15, position: 1)
      xp = quest_fixture(kind: "xp_earned", target: 30, xp_reward: 20, position: 2)
      note = quest_fixture(kind: "note_written", target: 1, xp_reward: 10, position: 3)

      status = fn ->
        for s <- Gamification.settle_quests(user), do: {s.quest.id, s.progress, s.completed}
      end

      # activité d'hier : ne compte pas aujourd'hui
      {:ok, :awarded} = Progress.complete(user, a)

      Repo.update_all(from(p in LessonProgress, where: p.lesson_id == ^a.id),
        set: [completed_at: days_ago(1)]
      )

      Repo.update_all(from(e in XpEvent, where: e.user_id == ^user),
        set: [inserted_at: days_ago(1)]
      )

      assert status.() == [{lessons.id, 0, false}, {xp.id, 0, false}, {note.id, 0, false}]

      {:ok, :awarded} = Progress.complete(user, b)
      assert status.() == [{lessons.id, 1, false}, {xp.id, 15, false}, {note.id, 0, false}]

      # 2e leçon du jour : quête réglée après la progression (+15) ; ces 15 XP ne comptent pas pour « 30 XP »
      {:ok, :awarded} = Progress.complete(user, c)
      today = Date.utc_today() |> Date.to_iso8601()
      assert quest_rewards(user) == [{"quest:#{lessons.id}:#{today}", 15}]
      assert status.() == [{lessons.id, 2, true}, {xp.id, 25, false}, {note.id, 0, false}]

      # une note vide ne compte pas ; une note écrite aujourd'hui, si (réglée à l'enregistrement)
      :ok = Progress.save_text(user, d, :notes, "   ")
      assert List.last(status.()) == {note.id, 0, false}
      :ok = Progress.save_text(user, d, :notes, "Count from zero.")
      assert {"quest:#{note.id}:#{today}", 10} in quest_rewards(user)

      # 5 XP de plus sans passer par une leçon : la quête est réglée à la lecture, une seule fois
      xp_event(user, "multiplayer:match:1", 5)
      assert status.() == [{lessons.id, 2, true}, {xp.id, 30, true}, {note.id, 1, true}]
      assert status.() == [{lessons.id, 2, true}, {xp.id, 30, true}, {note.id, 1, true}]

      assert Enum.sort(quest_rewards(user)) ==
               Enum.sort([
                 {"quest:#{lessons.id}:#{today}", 15},
                 {"quest:#{xp.id}:#{today}", 20},
                 {"quest:#{note.id}:#{today}", 10}
               ])

      # le lendemain, nouvelles quêtes : rien n'est encore fait
      tomorrow = Date.add(Date.utc_today(), 1)

      assert Enum.map(Gamification.settle_quests(user, tomorrow), &{&1.progress, &1.completed}) ==
               [{0, false}, {0, false}, {0, false}]
    end

    test "a note counts on the day it is saved, not when its lesson is touched later",
         %{user: user, d: quiz} do
      :ok = Progress.save_text(user, quiz, :notes, "Yesterday's thought.")

      Repo.update_all(from(p in LessonProgress, where: p.user_id == ^user),
        set: [notes_saved_at: days_ago(1), updated_at: days_ago(1)]
      )

      quest_fixture(kind: "note_written", target: 1, xp_reward: 10)
      # une tentative aujourd'hui modifie la ligne de progression, pas la date de la note
      {:ok, :none} = Progress.submit(user, quiz, false)
      assert [%{progress: 0, completed: false}] = Gamification.settle_quests(user)
      assert quest_rewards(user) == []
    end

    test "a quest reward is an XP gain: it can unlock XP badges", %{user: user, b: b} do
      quest_fixture(kind: "lessons_completed", target: 1, xp_reward: 15)
      badge = badge_fixture(criterion: "total_xp", target: 30)

      # 15 (leçon) + 15 (quête) = 30 XP
      {:ok, :awarded} = Progress.complete(user, b)
      assert earned(user) == ids([badge])
    end
  end

  test "public profile: level, XP, badge count, equipped badges, adventures completed" do
    user = user_id()
    [_one, two] = for _ <- 1..2, do: badge_fixture(criterion: "total_xp", target: 1)
    [only] = adventure_fixture(%{}, [[%{xp_reward: 10}]]) |> lessons_of()

    # 10 XP + 50 de bonus de fin d'aventure ; badges attribués par la progression elle-même
    {:ok, :awarded} = Progress.complete(user, only)
    {:ok, _} = Badges.equip(user, [two.id])

    assert %{
             user_id: ^user,
             level: 1,
             xp: 60,
             badges_earned: 2,
             adventures_completed: 1,
             equipped: [{badge, 1}]
           } = Gamification.profile(user)

    assert badge.id == two.id

    assert %{xp: 0, level: 1, badges_earned: 0, equipped: [], adventures_completed: 0} =
             Gamification.profile(user_id())
  end
end
