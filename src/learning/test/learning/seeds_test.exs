defmodule MlLearning.SeedsTest do
  use MlLearning.DataCase, async: true
  import ExUnit.CaptureIO
  alias MlLearning.{Catalog, Progress}
  alias MlLearning.Catalog.{Adventure, Lesson}
  alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}

  defp counts,
    do:
      for(
        s <- [Adventure, Lesson, Enrollment, LessonProgress, XpEvent],
        do: Repo.aggregate(s, :count)
      )

  test "seeds are idempotent and give lea_moreau five days of progress" do
    capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)
    first = counts()
    capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)
    assert counts() == first
    assert [4, 16, 2, 5, 6] = first

    assert %{entries: [%{slug: "la-machine-de-l-alchimiste", premium: true}]} =
             Catalog.list_adventures(%{"access" => "premium"})

    {:ok, forest} = Catalog.fetch_adventure("la-foret-des-murmures")

    assert Enum.map(forest.chapters, & &1.title) == [
             "Arrivée au bosquet",
             "Le bosquet des boucles"
           ]

    assert forest |> Catalog.lessons() |> Enum.map(& &1.kind) == ~w(story exercise coding)

    kinds = fn slug ->
      {:ok, adventure} = Catalog.fetch_adventure(slug)
      adventure |> Catalog.lessons() |> Enum.map(&{&1.kind, &1})
    end

    assert [_, _, _, {"video", video}, {"simulation", orbit}, {"minigame", sky}] =
             kinds.("l-atlas-celeste")

    assert [_, _, {"simulation", steam}, {"minigame", valve}] =
             kinds.("la-machine-de-l-alchimiste")

    assert [_, _, {"minigame", sources}] = kinds.("les-gardiens-des-archives")

    assert %{
             "video" => %{"src" => "/media/lessons/reading-the-night-sky.webm"},
             "captions" => [_, _]
           } =
             video.content

    # les simulations seedées ont une solution atteignable, les mini-jeux une solution cachée
    solved = fn lesson, values ->
      {:ok, _, result} = MlLearning.Sim.simulate(lesson.content, values, mode: "elixir")
      MlLearning.Sim.evaluate(lesson.content, lesson.solution, result).correct
    end

    assert solved.(orbit, %{"velocity" => 6.3})
    refute solved.(orbit, %{})
    assert solved.(steam, %{"h2" => 2, "o2" => 1, "h2o" => 2})
    assert %{"game" => "constellation"} = sky.content
    assert length(sky.solution["path"]) == 8
    assert %{"order" => [_, _, _, _, _]} = valve.solution
    assert %{"order" => [_, _, _, _, _]} = sources.solution

    lea = MlShared.Demo.user("lea_moreau").id
    dashboard = Progress.dashboard(lea)
    assert %{xp: 155, level: 2, into_level: 5, streak: 5} = dashboard
    assert dashboard.week |> Enum.drop(2) |> Enum.map(& &1.xp) == [10, 20, 90, 15, 20]
    assert %{slug: "l-atlas-celeste", percent: 33} = dashboard.current

    assert Enum.map(dashboard.recommendations, & &1.slug) == [
             "les-gardiens-des-archives",
             "la-machine-de-l-alchimiste"
           ]
  end
end
