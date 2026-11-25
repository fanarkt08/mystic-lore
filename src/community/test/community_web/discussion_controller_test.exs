defmodule MlCommunityWeb.DiscussionControllerTest do
  use MlCommunityWeb.ConnCase, async: true
  import Ecto.Query
  alias MlCommunity.{Discussion, Follow, Repo}

  setup do
    {:ok, a: uuid(), b: uuid()}
  end

  defp create(user, attrs), do: api(:post, "/api/discussions", user, attrs)

  @valid %{
    "category" => "help-questions",
    "title" => "  Why   does range(3) stop at 2?  ",
    "body" => "The grove only waters three saplings: 0, 1 and 2."
  }

  describe "categories" do
    test "the five seeded categories; Announcements is reserved to the staff", %{a: a} do
      staff = uuid()
      stub_services(staff: [staff])

      %{"categories" => categories} = api(:get, "/api/categories", a) |> json_response(200)

      assert Enum.map(categories, & &1["slug"]) ==
               ~w(announcements help-questions showcase study-groups off-topic)

      assert [%{"name" => "Announcements", "staff_only" => true, "can_post" => false} | rest] =
               categories

      assert Enum.all?(rest, & &1["can_post"])

      %{"categories" => [announcements | _]} =
        api(:get, "/api/categories", staff) |> json_response(200)

      assert announcements["can_post"]

      # visiteur : lecture seule
      %{"categories" => visitor} = api(:get, "/api/categories", nil) |> json_response(200)
      refute Enum.any?(visitor, & &1["can_post"])
    end
  end

  describe "create" do
    test "slug derived from the title with a random suffix, author follows it", %{a: a} do
      %{"discussion" => d} = create(a, @valid) |> json_response(201)

      assert d["title"] == "Why does range(3) stop at 2?"
      assert d["slug"] =~ ~r/^why-does-range-3-stop-at-2-[a-z2-7]{8}$/
      assert %{"id" => ^a, "username" => "user_" <> _} = d["author"]
      assert d["category"] == %{"slug" => "help-questions", "name" => "Help & Questions"}

      assert %{"following" => true, "can_edit" => true, "voted" => false, "reply_count" => 0} =
               d

      assert d["status"] == "visible" and d["helpful_count"] == 0 and d["solved"] == false

      # même titre : autre slug
      %{"discussion" => again} = create(a, @valid) |> json_response(201)
      assert again["slug"] != d["slug"]
      assert Repo.get_by!(Follow, user_id: a, discussion_id: d["id"])
    end

    test "validation errors (422) and unknown category", %{a: a} do
      assert %{"error" => "invalid", "errors" => errors} =
               create(a, %{"title" => "Hey", "body" => "short"}) |> json_response(422)

      assert errors["category"] == ["can't be blank"]
      assert errors["title"] == ["should be at least 5 character(s)"]
      assert errors["body"] == ["should be at least 10 character(s)"]

      assert %{"errors" => %{"category" => ["is invalid"]}} =
               create(a, %{@valid | "category" => "dark-arts"}) |> json_response(422)

      assert %{"errors" => %{"body" => ["is invalid"]}} =
               create(a, %{@valid | "body" => "nul \u0000 byte in the body"})
               |> json_response(422)

      assert Repo.aggregate(Discussion, :count) == 0
    end

    test "only the staff opens discussions in Announcements (role checked at accounts)", %{a: a} do
      announcement = %{@valid | "category" => "announcements"}
      assert %{"error" => "forbidden"} = create(a, announcement) |> json_response(403)

      # un rôle « falsifié » dans le corps ou les en-têtes n'a aucun effet
      assert %{"error" => "forbidden"} =
               create(a, Map.merge(announcement, %{"role" => "admin", "staff" => true}))
               |> json_response(403)

      staff = uuid()
      stub_services(staff: [staff])
      assert %{"discussion" => _} = create(staff, announcement) |> json_response(201)
    end
  end

  describe "edit and delete" do
    setup %{a: a} do
      %{discussion: discussion!(a)}
    end

    test "the author edits title and body within 30 minutes", %{a: a, discussion: d} do
      %{"discussion" => edited} =
        api(:patch, "/api/discussions/#{d.slug}", a, %{
          "title" => "Range(3) explained",
          "body" => "Solved it myself: counting starts at zero.",
          "category" => "off-topic"
        })
        |> json_response(200)

      assert edited["title"] == "Range(3) explained"
      assert edited["edited_at"]
      # ni le slug ni la catégorie ne changent
      assert edited["slug"] == d.slug
      assert edited["category"]["slug"] == "help-questions"
    end

    test "IDOR: another member can neither edit nor delete", %{b: b, discussion: d} do
      assert %{"error" => "forbidden"} =
               api(:patch, "/api/discussions/#{d.slug}", b, %{"title" => "Hijacked title"})
               |> json_response(403)

      assert %{"error" => "forbidden"} =
               api(:delete, "/api/discussions/#{d.slug}", b) |> json_response(403)

      assert Repo.get!(Discussion, d.id).title == d.title
    end

    test "no edit after the 30-minute window, even by the author", %{a: a, discussion: d} do
      age!(d, 31)

      assert %{"error" => "edit_window_expired"} =
               api(:patch, "/api/discussions/#{d.slug}", a, %{"title" => "Too late to edit"})
               |> json_response(403)

      %{"discussion" => shown} = api(:get, "/api/discussions/#{d.slug}", a) |> json_response(200)
      refute shown["can_edit"]
    end

    test "logical deletion by the author: gone for everyone but the staff", %{
      a: a,
      b: b,
      discussion: d
    } do
      assert response(api(:delete, "/api/discussions/#{d.slug}", a), 204)
      assert Repo.get!(Discussion, d.id).status == "deleted"

      for user <- [a, b, nil] do
        assert api(:get, "/api/discussions/#{d.slug}", user) |> json_response(404)
      end

      staff = uuid()
      stub_services(staff: [staff])

      assert %{"discussion" => %{"status" => "deleted"}} =
               api(:get, "/api/discussions/#{d.slug}", staff) |> json_response(200)
    end
  end

  describe "show" do
    test "discussion and its replies, chronological, 50 per page", %{a: a, b: b} do
      d = discussion!(a)
      reply!(b, d, "First answer")
      reply!(a, d, "Second answer")

      %{"discussion" => shown, "replies" => replies} =
        api(:get, "/api/discussions/#{d.slug}", nil) |> json_response(200)

      assert shown["body"] == d.body
      assert shown["reply_count"] == 2
      assert %{"page" => 1, "total" => 2, "total_pages" => 1, "entries" => entries} = replies
      assert Enum.map(entries, & &1["body"]) == ["First answer", "Second answer"]

      assert %{"author" => %{"id" => ^b}, "can_edit" => false, "solution" => false} =
               hd(entries)

      for i <- 1..49,
          do:
            MlCommunity.Repo.insert!(%MlCommunity.Reply{
              discussion_id: d.id,
              author_id: b,
              body: "Reply #{i}"
            })

      %{"replies" => page2} =
        api(:get, "/api/discussions/#{d.slug}?page=2", nil) |> json_response(200)

      assert %{"page" => 2, "total" => 51, "total_pages" => 2} = page2
      assert length(page2["entries"]) == 1
    end

    test "unknown slug: 404", %{a: a} do
      assert %{"error" => "not_found"} =
               api(:get, "/api/discussions/nope", a) |> json_response(404)
    end
  end

  describe "list" do
    test "pagination: 10 per page, invalid page → 1, beyond → empty", %{a: a} do
      for i <- 1..12, do: insert_discussion!(a, title: "Discussion #{i}")

      page1 = api(:get, "/api/discussions", nil) |> json_response(200)
      assert %{"page" => 1, "total" => 12, "total_pages" => 2} = page1
      assert length(page1["entries"]) == 10

      assert %{"page" => 2, "entries" => [_, _]} =
               api(:get, "/api/discussions?page=2", nil) |> json_response(200)

      assert %{"page" => 1} = api(:get, "/api/discussions?page=zero", nil) |> json_response(200)

      assert %{"page" => 3, "entries" => []} =
               api(:get, "/api/discussions?page=3", nil) |> json_response(200)
    end

    test "search in title and body, LIKE wildcards escaped", %{a: a} do
      insert_discussion!(a, title: "100% of saplings watered", body: "A loop did it.")
      insert_discussion!(a, title: "Constellations", body: "Orion's belt has 3 stars.")
      insert_discussion!(a, title: "Snake_case runes", body: "Underscores everywhere.")

      titles = fn q ->
        api(:get, "/api/discussions?" <> URI.encode_query(q: q), nil)
        |> json_response(200)
        |> Map.fetch!("entries")
        |> Enum.map(& &1["title"])
      end

      assert titles.("100%") == ["100% of saplings watered"]
      assert titles.("%") == ["100% of saplings watered"]
      assert titles.("e_c") == ["Snake_case runes"]
      assert titles.("ORION") == ["Constellations"]
      assert titles.("_") == ["Snake_case runes"]
    end

    test "filters: category, unanswered, solved, following; sorts", %{a: a, b: b} do
      answered = discussion!(a, %{"title" => "Answered question"})
      reply!(b, answered)
      solved = discussion!(a, %{"title" => "Solved question"})
      solution = reply!(b, solved)
      {:ok, _} = MlCommunity.Posts.set_solution(viewer(a), solved.slug, solution.id)
      lonely = discussion!(b, %{"title" => "Lonely question", "category" => "off-topic"})
      {:ok, _} = MlCommunity.Votes.set(viewer(a), lonely, true)

      titles = fn query, user ->
        api(:get, "/api/discussions?" <> query, user)
        |> json_response(200)
        |> Map.fetch!("entries")
        |> Enum.map(& &1["title"])
      end

      assert titles.("category=off-topic", nil) == ["Lonely question"]
      assert titles.("filter=unanswered", nil) == ["Lonely question"]
      assert titles.("filter=solved", nil) == ["Solved question"]
      # suivi : a suit ses discussions ; b suit les siennes et celles où il a répondu
      assert titles.("filter=following", a) == ["Solved question", "Answered question"]

      assert Enum.sort(titles.("filter=following", b)) ==
               Enum.sort(["Lonely question", "Solved question", "Answered question"])

      assert titles.("filter=following", nil) == []
      assert hd(titles.("sort=helpful", nil)) == "Lonely question"
      # récent : dernière activité d'abord
      assert titles.("", nil) == ["Lonely question", "Solved question", "Answered question"]

      [entry] =
        api(:get, "/api/discussions?filter=solved", a)
        |> json_response(200)
        |> Map.fetch!("entries")

      assert %{"solved" => true, "reply_count" => 1, "following" => true} = entry
      assert entry["excerpt"] == solved.body
    end

    test "pinned discussions come first in the default sort", %{a: a} do
      insert_discussion!(a,
        title: "Old pinned",
        pinned: true,
        last_activity_at: DateTime.add(DateTime.utc_now(), -3600)
      )

      insert_discussion!(a, title: "Fresh")

      assert ["Old pinned", "Fresh"] =
               api(:get, "/api/discussions", nil)
               |> json_response(200)
               |> Map.fetch!("entries")
               |> Enum.map(& &1["title"])
    end
  end

  describe "follow, vote, solution" do
    setup %{a: a, b: b} do
      d = discussion!(a)
      %{discussion: d, reply: reply!(b, d)}
    end

    test "manual follow / unfollow are idempotent", %{b: b, discussion: d} do
      c = uuid()

      for _ <- 1..2 do
        assert %{"following" => true} =
                 api(:put, "/api/discussions/#{d.slug}/follow", c) |> json_response(200)
      end

      assert Repo.aggregate(where(Follow, user_id: ^c), :count) == 1

      for _ <- 1..2 do
        assert %{"following" => false} =
                 api(:delete, "/api/discussions/#{d.slug}/follow", b) |> json_response(200)
      end

      refute Repo.get_by(Follow, user_id: b, discussion_id: d.id)
    end

    test "helpful vote on a discussion: idempotent, never on one's own", %{
      a: a,
      b: b,
      discussion: d
    } do
      for _ <- 1..3 do
        assert %{"voted" => true, "helpful_count" => 1} =
                 api(:put, "/api/discussions/#{d.slug}/vote", b) |> json_response(200)
      end

      assert %{"discussion" => %{"voted" => true}} =
               api(:get, "/api/discussions/#{d.slug}", b) |> json_response(200)

      for _ <- 1..2 do
        assert %{"voted" => false, "helpful_count" => 0} =
                 api(:delete, "/api/discussions/#{d.slug}/vote", b) |> json_response(200)
      end

      assert %{"error" => "own_content"} =
               api(:put, "/api/discussions/#{d.slug}/vote", a) |> json_response(403)
    end

    test "only the discussion author marks (and unmarks) a solution", %{
      a: a,
      b: b,
      discussion: d,
      reply: r
    } do
      assert %{"error" => "forbidden"} =
               api(:put, "/api/discussions/#{d.slug}/solution", b, %{"reply_id" => r.id})
               |> json_response(403)

      assert %{"solution_reply_id" => id} =
               api(:put, "/api/discussions/#{d.slug}/solution", a, %{"reply_id" => r.id})
               |> json_response(200)

      assert id == r.id

      %{"discussion" => shown, "replies" => %{"entries" => [reply]}} =
        api(:get, "/api/discussions/#{d.slug}", nil) |> json_response(200)

      assert shown["solved"] and reply["solution"]

      # une réponse d'une autre discussion n'est pas une solution possible
      other = discussion!(b, %{"title" => "Another question"})
      foreign = reply!(a, other)

      assert %{"errors" => %{"reply_id" => ["is invalid"]}} =
               api(:put, "/api/discussions/#{d.slug}/solution", a, %{"reply_id" => foreign.id})
               |> json_response(422)

      assert %{"solution_reply_id" => nil} =
               api(:delete, "/api/discussions/#{d.slug}/solution", a) |> json_response(200)
    end
  end
end
