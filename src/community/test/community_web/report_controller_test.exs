defmodule MlCommunityWeb.ReportControllerTest do
  use MlCommunityWeb.ConnCase, async: true
  alias MlCommunity.{Report, Repo}

  setup do
    {author, reporter} = {uuid(), uuid()}
    d = discussion!(author)

    {:ok,
     author: author,
     reporter: reporter,
     discussion: d,
     reply: reply!(author, d, "Buy shiny rune stones!")}
  end

  defp report(user, attrs), do: api(:post, "/api/reports", user, attrs)

  test "reporting a reply keeps a snapshot that survives edits and deletion", %{
    author: author,
    reporter: reporter,
    discussion: d,
    reply: r
  } do
    assert %{"id" => id} =
             report(reporter, %{
               "target_type" => "reply",
               "target_id" => r.id,
               "reason" => "spam",
               "details" => "  advertising  "
             })
             |> json_response(201)

    {:ok, _} =
      MlCommunity.Posts.update_reply(viewer(author), r.id, %{"body" => "Nothing to see here."})

    :ok = MlCommunity.Posts.delete_reply(viewer(author), r.id)

    assert %Report{
             reporter_id: ^reporter,
             target_type: "reply",
             reason: "spam",
             details: "advertising",
             status: "open",
             snapshot: snapshot
           } = Repo.get!(Report, id)

    assert snapshot["body"] == "Buy shiny rune stones!"
    assert snapshot["author_id"] == author
    assert snapshot["discussion_slug"] == d.slug
    assert snapshot["title"] == d.title
    assert snapshot["status"] == "visible"
    assert {:ok, _, _} = DateTime.from_iso8601(snapshot["posted_at"])
  end

  test "reporting a discussion; a single open report per reporter and target", %{
    reporter: reporter,
    discussion: d
  } do
    attrs = %{"target_type" => "discussion", "target_id" => d.id, "reason" => "inappropriate"}
    assert %{"id" => first} = report(reporter, attrs) |> json_response(201)
    assert %{"error" => "already_reported"} = report(reporter, attrs) |> json_response(409)

    assert %{"error" => "already_reported"} =
             report(reporter, %{attrs | "reason" => "other"}) |> json_response(409)

    # un autre membre peut signaler ; après résolution, le même membre peut signaler à nouveau
    assert report(uuid(), attrs) |> json_response(201)
    staff = uuid()
    stub_services(staff: [staff])

    assert api(:post, "/api/moderation/reports/#{first}/resolve", staff, %{"action" => "dismiss"})
           |> json_response(200)

    assert report(reporter, attrs) |> json_response(201)

    assert %{snapshot: %{"title" => title, "body" => body}} = Repo.get!(Report, first)
    assert title == d.title and body == d.body
  end

  test "validation, own content, unknown or invisible target", %{
    author: author,
    reporter: reporter,
    reply: r
  } do
    assert %{"errors" => errors} = report(reporter, %{}) |> json_response(422)
    assert errors |> Map.keys() |> Enum.sort() == ~w(reason target_id target_type)

    assert %{"errors" => %{"target_type" => ["is invalid"], "reason" => ["is invalid"]}} =
             report(reporter, %{"target_type" => "user", "target_id" => r.id, "reason" => "meh"})
             |> json_response(422)

    assert %{"errors" => %{"target_id" => ["cannot be your own content"]}} =
             report(author, %{"target_type" => "reply", "target_id" => r.id, "reason" => "spam"})
             |> json_response(422)

    for target <- [uuid(), "not-a-uuid"] do
      assert %{"errors" => %{"target_id" => ["is invalid"]}} =
               report(reporter, %{
                 "target_type" => "reply",
                 "target_id" => target,
                 "reason" => "spam"
               })
               |> json_response(422)
    end

    assert %{"errors" => %{"details" => ["should be at most 2000 character(s)"]}} =
             report(reporter, %{
               "target_type" => "reply",
               "target_id" => r.id,
               "reason" => "other",
               "details" => String.duplicate("x", 2001)
             })
             |> json_response(422)

    assert Repo.aggregate(Report, :count) == 0
  end
end
