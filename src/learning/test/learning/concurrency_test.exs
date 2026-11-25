defmodule MlLearning.ConcurrencyTest do
  @moduledoc """
  Vraie concurrence : chaque tâche a sa connexion PostgreSQL (hors bac à sable, données validées),
  nettoyées à la fin. Module synchrone : il ne tourne pas en même temps que les tests asynchrones.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias MlLearning.{Fixtures, Grader, Offline, Progress, Repo}
  alias MlLearning.Catalog.Adventure
  alias MlLearning.Offline.Action
  alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}

  setup do
    user = Fixtures.user_id()
    slug = "concurrency-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from e in XpEvent, where: e.user_id == ^user)
        Repo.delete_all(from a in Action, where: a.user_id == ^user)
        Repo.delete_all(from a in Adventure, where: a.slug == ^slug)
      end)
    end)

    %{user: user, slug: slug}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp in_parallel(funs) do
    funs
    |> Task.async_stream(&unboxed/1, max_concurrency: length(funs), timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp lessons(slug, chapters),
    do:
      unboxed(fn ->
        Fixtures.adventure_fixture(%{slug: slug}, chapters) |> Fixtures.lessons_of()
      end)

  defp xp_refs(user),
    do:
      unboxed(fn -> Repo.all(from e in XpEvent, where: e.user_id == ^user, select: e.ref_key) end)

  test "concurrent awards of the same reward insert exactly one XP event", %{user: user} do
    results =
      in_parallel(for _ <- 1..12, do: fn -> Progress.award_xp(user, "lesson:race", 10) end)

    assert Enum.frequencies(results) == %{awarded: 1, duplicate: 11}
    assert xp_refs(user) == ["lesson:race"]
  end

  test "concurrent correct submissions of one lesson: XP once, every attempt counted",
       %{user: user, slug: slug} do
    [quiz, _story] = lessons(slug, [[Fixtures.quiz(), %{}]])

    results = in_parallel(for _ <- 1..8, do: fn -> Progress.submit(user, quiz, true) end)

    assert Enum.frequencies(results) == %{{:ok, :awarded} => 1, {:ok, :duplicate} => 7}
    assert xp_refs(user) == ["lesson:#{quiz.id}"]

    assert %{attempts: 8, status: "completed"} =
             unboxed(fn -> Repo.get_by!(LessonProgress, user_id: user) end)
  end

  test "completing all lessons at once grants the adventure bonus exactly once (never lost)",
       %{user: user, slug: slug} do
    lessons = lessons(slug, [for(_ <- 1..5, do: %{}), for(_ <- 1..5, do: %{})])

    results = in_parallel(for lesson <- lessons, do: fn -> Progress.complete(user, lesson) end)

    assert Enum.all?(results, &(&1 == {:ok, :awarded}))
    refs = xp_refs(user)
    assert length(refs) == 11
    assert Enum.count(refs, &String.starts_with?(&1, "adventure:")) == 1
    assert unboxed(fn -> Repo.get_by!(Enrollment, user_id: user) end).completed_at
  end

  test "simulation and mini-game: concurrent correct answers graded by the server give XP once",
       %{user: user, slug: slug} do
    [orbit, game] = lessons(slug, [[Fixtures.orbit_lesson(), Fixtures.constellation_lesson()]])
    ids = Map.new(game.content["stars"], &{&1["name"], &1["id"]})
    path = Jason.encode!(%{"moves" => Enum.map(~w(Alpha Beta Gamma Beta), &ids[&1])})

    answer = fn lesson, answer ->
      fn ->
        {:ok, %{correct: true}} = Grader.grade(lesson, answer, user)
        Progress.submit(user, lesson, true)
      end
    end

    results =
      in_parallel(
        for(_ <- 1..6, do: answer.(orbit, ~s({"velocity": 6.3}))) ++
          for(_ <- 1..6, do: answer.(game, path))
      )

    assert Enum.frequencies(results) == %{{:ok, :awarded} => 2, {:ok, :duplicate} => 10}

    assert Enum.sort(xp_refs(user)) |> Enum.filter(&String.starts_with?(&1, "lesson:")) ==
             Enum.sort(["lesson:#{orbit.id}", "lesson:#{game.id}"])
  end

  test "offline replays: concurrent requests with the SAME key count one attempt and one XP, all get the receipt",
       %{user: user, slug: slug} do
    [quiz, _story] = lessons(slug, [[Fixtures.quiz(), %{}]])
    replay = %{key: Ecto.UUID.generate(), revision: quiz.revision}

    results = in_parallel(for _ <- 1..8, do: fn -> Offline.submit(user, quiz, "1", replay) end)

    assert Enum.count(results, &match?({:ok, %{"correct" => true}, false}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{"correct" => true}, true}, &1)) == 7
    # every caller sees the same stored answer
    assert results |> Enum.map(fn {:ok, response, _} -> response end) |> Enum.uniq() |> length() ==
             1

    assert xp_refs(user) == ["lesson:#{quiz.id}"]

    assert %{attempts: 1, status: "completed"} =
             unboxed(fn -> Repo.get_by!(LessonProgress, user_id: user) end)
  end
end
