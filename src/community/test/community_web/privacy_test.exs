defmodule MlCommunityWeb.PrivacyTest do
  use MlCommunityWeb.ConnCase, async: true
  import Ecto.Query, only: [from: 2]
  alias MlCommunity.{Discussion, Follow, Reply, Report, Repo, Vote}

  defp caller(service, user_id \\ nil) do
    put_req_header(
      build_conn(),
      "authorization",
      "Bearer " <> MlShared.InternalToken.sign(service, user_id)
    )
  end

  setup do
    [me, other] = for _ <- 1..2, do: uuid()
    stub_services()
    mine = discussion!(me, %{"title" => "My question about loops"})
    theirs = discussion!(other, %{"title" => "Their showcase of a grove"})
    reply!(other, mine, "An answer written by someone else")
    my_reply = reply!(me, theirs, "My kind reply to their showcase")
    their_reply = reply!(other, theirs, "Their own follow-up message")
    Repo.insert!(%Vote{user_id: me, target_type: "reply", target_id: their_reply.id})

    Repo.insert!(%Report{
      reporter_id: me,
      target_type: "reply",
      target_id: their_reply.id,
      reason: "spam",
      details: "Looks like an advert",
      snapshot: %{"body" => "Snapshot of their reply"}
    })

    %{me: me, other: other, mine: mine, theirs: theirs, my_reply: my_reply}
  end

  test "only the accounts service may call them (403 otherwise)", %{me: me} do
    for conn <- [caller("web", me), caller("social"), caller("studio")] do
      assert %{"error" => "forbidden"} =
               conn |> get("/api/internal/users/#{me}/export") |> json_response(403)

      assert conn |> recycle() |> delete("/api/internal/users/#{me}") |> json_response(403)
    end

    assert Repo.aggregate(from(f in Follow, where: f.user_id == ^me), :count) == 2
  end

  test "export: own discussions, replies, votes, follows, reports, nothing written by others", %{
    me: me,
    mine: mine,
    theirs: theirs
  } do
    assert %{"data" => data} =
             caller("accounts") |> get("/api/internal/users/#{me}/export") |> json_response(200)

    assert [%{"title" => "My question about loops", "status" => "visible"}] = data["discussions"]

    assert [%{"body" => "My kind reply to their showcase", "discussion" => slug}] =
             data["replies"]

    assert slug == theirs.slug
    assert [%{"target_type" => "reply"}] = data["votes"]

    assert Enum.sort(Enum.map(data["follows"], & &1["discussion"])) ==
             Enum.sort([mine.slug, slug])

    assert [%{"reason" => "spam", "details" => "Looks like an advert"}] = data["reports_filed"]
    assert data["moderation_actions"] == []

    dump = inspect(data)
    refute dump =~ "someone else"
    refute dump =~ "Their own follow-up"
    refute dump =~ "Snapshot of their reply"

    assert caller("accounts") |> get("/api/internal/users/nope/export") |> json_response(404)
  end

  test "DELETE: follows removed; discussions, replies, votes and reports kept; idempotent", %{
    me: me,
    other: other,
    mine: mine,
    my_reply: my_reply
  } do
    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)

    assert Repo.all(from f in Follow, where: f.user_id == ^me) == []

    assert [_] =
             Repo.all(
               from f in Follow, where: f.user_id == ^other and f.discussion_id == ^mine.id
             )

    assert %Discussion{author_id: ^me, status: "visible"} = Repo.get!(Discussion, mine.id)
    assert %Reply{author_id: ^me} = Repo.get!(Reply, my_reply.id)
    assert Repo.aggregate(from(v in Vote, where: v.user_id == ^me), :count) == 1
    assert Repo.aggregate(from(r in Report, where: r.reporter_id == ^me), :count) == 1

    # la discussion reste lisible, rattachée à l'identifiant de son auteur
    assert %{"discussion" => %{"author" => %{"id" => ^me}}} =
             api(:get, "/api/discussions/#{mine.slug}", other) |> json_response(200)

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
  end
end
