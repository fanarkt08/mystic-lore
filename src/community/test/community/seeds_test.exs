defmodule MlCommunity.SeedsTest do
  # UUID fixes de démonstration partagés : pas d'exécution concurrente avec d'autres tests.
  use MlCommunity.DataCase, async: false
  import ExUnit.CaptureIO
  alias MlCommunity.{Discussion, Follow, Forum, Reply, Report, Vote}

  defp run_seeds, do: capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)

  test "seeds are idempotent and reference the demo members" do
    run_seeds()
    schemas = [Discussion, Reply, Vote, Follow, Report]
    counts = for schema <- schemas, do: Repo.aggregate(schema, :count)
    run_seeds()
    assert counts == for(schema <- schemas, do: Repo.aggregate(schema, :count))

    assert [6, 8, 7, _, 1] = counts
    demo = MapSet.new(MlShared.Demo.users(), & &1.id)
    assert Repo.all(from d in Discussion, select: d.author_id) |> Enum.all?(&(&1 in demo))
    assert Repo.all(from r in Reply, select: r.author_id) |> Enum.all?(&(&1 in demo))

    # vue d'un visiteur : annonce épinglée en tête, une question résolue, une sans réponse
    page = Forum.list_discussions(%MlCommunity.Viewer{}, %{})
    assert [%Discussion{pinned: true, category: "announcements"} | _] = page.entries

    assert [%{title: "Pourquoi range(3) s'arrête à 2 dans la Forêt des murmures\u00A0?"}] =
             Forum.list_discussions(%MlCommunity.Viewer{}, %{"filter" => "solved"}).entries

    unanswered = Forum.list_discussions(%MlCommunity.Viewer{}, %{"filter" => "unanswered"})

    assert Enum.map(unanswered.entries, & &1.title) == [
             "Bienvenue sur le forum de MysticLore",
             "Peut-on arroser les arbres à l'envers avec une boucle\u00A0?"
           ]

    # compteurs « utile » cohérents avec les lignes de vote
    for reply <- Repo.all(Reply) do
      votes = Repo.aggregate(where(Vote, target_type: "reply", target_id: ^reply.id), :count)
      assert reply.helpful_count == votes
    end

    assert [%Report{status: "open", reason: "spam", snapshot: %{"body" => "Premier\u00A0!" <> _}}] =
             Repo.all(Report)

    assert Enum.all?(
             Repo.all(Discussion),
             &(DateTime.compare(&1.inserted_at, DateTime.utc_now()) == :lt)
           )
  end
end
