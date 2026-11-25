defmodule MlLearning.ProgressTest do
  use MlLearning.DataCase, async: true
  alias MlLearning.Progress
  alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}

  defp xp_rows(user),
    do:
      Repo.all(
        from e in XpEvent,
          where: e.user_id == ^user,
          order_by: e.ref_key,
          select: {e.ref_key, e.amount}
      )

  test "award_xp is idempotent per (user, ref_key)" do
    user = user_id()
    assert Progress.award_xp(user, "lesson:x", 10) == :awarded
    assert Progress.award_xp(user, "lesson:x", 10) == :duplicate
    assert Progress.award_xp(user_id(), "lesson:x", 10) == :awarded
    assert xp_rows(user) == [{"lesson:x", 10}]
  end

  test "opening a lesson enrolls the user (idempotently) and remembers the lesson" do
    user = user_id()
    adventure = adventure_fixture(%{}, [[%{}, %{}]])
    [_first, second] = lessons_of(adventure)

    assert %{enrolled: false, progress: nil, resume_lesson_id: nil} =
             Progress.state(user, adventure)

    assert %{enrolled: false} = Progress.state(nil, adventure)

    assert {:ok, %LessonProgress{status: "in_progress", attempts: 0}} =
             Progress.open(user, second)

    assert {:ok, %LessonProgress{}} = Progress.open(user, second)
    assert :ok = Progress.enroll(user, adventure)

    assert Repo.aggregate(from(e in Enrollment, where: e.user_id == ^user), :count) == 1

    assert %{enrolled: true, progress: %{done: 0, total: 2, percent: 0}} =
             state = Progress.state(user, adventure)

    assert state.resume_lesson_id == second.id
  end

  test "completing a story awards its XP once; finishing the adventure adds a single 50 XP bonus" do
    user = user_id()
    adventure = adventure_fixture(%{}, [[%{xp_reward: 10}], [%{xp_reward: 15}]])
    [a, b] = lessons_of(adventure)

    assert {:ok, :awarded} = Progress.complete(user, a)
    assert {:ok, :duplicate} = Progress.complete(user, a)
    assert xp_rows(user) == [{"lesson:#{a.id}", 10}]

    assert {:ok, :awarded} = Progress.complete(user, b)
    assert {:ok, :duplicate} = Progress.complete(user, b)

    assert Enum.sort(xp_rows(user)) ==
             Enum.sort([
               {"adventure:#{adventure.id}", 50},
               {"lesson:#{a.id}", 10},
               {"lesson:#{b.id}", 15}
             ])

    assert %{xp: 75, level: 1, into_level: 75} = Progress.dashboard(user)
    assert %Enrollment{completed_at: %DateTime{}} = Repo.get_by(Enrollment, user_id: user)

    assert %{progress: %{done: 2, total: 2, percent: 100}, resume_lesson_id: nil} =
             Progress.state(user, adventure)
  end

  test "every submission counts as an attempt; only a correct one completes the lesson" do
    user = user_id()
    [lesson] = adventure_fixture(%{}, [[quiz()]]) |> lessons_of()

    assert {:ok, :none} = Progress.submit(user, lesson, false)
    assert {:ok, %{status: "in_progress", attempts: 1}} = Progress.open(user, lesson)
    assert {:ok, :awarded} = Progress.submit(user, lesson, true)
    assert {:ok, :duplicate} = Progress.submit(user, lesson, true)
    assert {:ok, :none} = Progress.submit(user, lesson, false)
    assert {:ok, %{status: "completed", attempts: 4}} = Progress.open(user, lesson)
    # Aventure d'une seule leçon : XP de la leçon + bonus.
    assert Progress.dashboard(user).xp == 20 + 50
  end

  test "notes and drafts belong to each user" do
    user = user_id()
    [lesson] = adventure_fixture() |> lessons_of()

    assert :ok = Progress.save_text(user, lesson, :notes, "Loops repeat spells.")
    assert :ok = Progress.save_text(user, lesson, :draft, "water(0)")

    assert {:ok, %{notes: "Loops repeat spells.", draft: "water(0)"}} =
             Progress.open(user, lesson)

    assert {:ok, %{notes: nil, draft: nil}} = Progress.open(user_id(), lesson)
  end

  test "resume points to the first unfinished lesson from the last one opened, wrapping around" do
    user = user_id()
    adventure = adventure_fixture(%{}, [[%{}, %{}], [%{}]])
    [a, b, c] = lessons_of(adventure)

    {:ok, :awarded} = Progress.complete(user, b)
    assert Progress.state(user, adventure).resume_lesson_id == c.id
    {:ok, :awarded} = Progress.complete(user, c)
    assert Progress.state(user, adventure).resume_lesson_id == a.id
  end

  describe "dashboard/2" do
    test "level, streak and week come from XP events, by UTC day" do
      user = user_id()

      events = [
        {~D[2026-11-23], ~T[00:00:01], 40},
        {~D[2026-11-22], ~T[23:59:59], 30},
        {~D[2026-11-21], ~T[12:00:00], 50},
        {~D[2026-11-21], ~T[13:00:00], 10},
        {~D[2026-11-19], ~T[08:00:00], 25},
        {~D[2026-11-10], ~T[08:00:00], 100}
      ]

      Repo.insert_all(
        XpEvent,
        for {{date, time, amount}, i} <- Enum.with_index(events) do
          at = DateTime.new!(date, time, "Etc/UTC")

          %{
            id: Ecto.UUID.generate(),
            user_id: user,
            ref_key: "test:#{i}",
            amount: amount,
            inserted_at: at
          }
        end
      )

      dashboard = Progress.dashboard(user, ~D[2026-11-23])
      assert %{xp: 255, level: 2, into_level: 105, per_level: 150, streak: 3} = dashboard

      assert dashboard.week == [
               %{date: ~D[2026-11-17], xp: 0},
               %{date: ~D[2026-11-18], xp: 0},
               %{date: ~D[2026-11-19], xp: 25},
               %{date: ~D[2026-11-20], xp: 0},
               %{date: ~D[2026-11-21], xp: 60},
               %{date: ~D[2026-11-22], xp: 30},
               %{date: ~D[2026-11-23], xp: 40}
             ]

      # Sans XP aujourd'hui, la série tient jusqu'à hier ; un jour entier sans XP la remet à zéro.
      assert Progress.dashboard(user, ~D[2026-11-24]).streak == 3
      assert Progress.dashboard(user, ~D[2026-11-25]).streak == 0
    end

    test "a new member is level 1 with no current adventure" do
      assert %{xp: 0, level: 1, into_level: 0, streak: 0, current: nil, week: week} =
               Progress.dashboard(user_id())

      assert length(week) == 7
    end

    test "current adventure and recommendations (not enrolled, free first)" do
      user = user_id()
      done = adventure_fixture(%{title: "Done"}, [[%{}]])
      current = adventure_fixture(%{title: "Current"}, [[%{}, %{}, %{}]])
      adventure_fixture(%{title: "A premium tale", premium: true})
      adventure_fixture(%{title: "Z free tale"})
      [only] = lessons_of(done)
      [a, b, _c] = lessons_of(current)

      {:ok, _} = Progress.complete(user, only)
      {:ok, _} = Progress.complete(user, a)
      {:ok, _} = Progress.open(user, b)

      dashboard = Progress.dashboard(user)

      assert dashboard.current == %{
               slug: current.slug,
               title: "Current",
               percent: 33,
               resume_lesson_id: b.id
             }

      assert Enum.map(dashboard.recommendations, & &1.title) == ["Z free tale", "A premium tale"]
    end
  end
end
