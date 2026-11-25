defmodule MysticWeb.Studio.PagesLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.StudioFixtures

  defp open(conn, routes, path) do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(path)
    view
  end

  describe "/studio" do
    test "my projects and the projects shared with me", %{conn: conn} do
      summary = %{
        "id" => "p1",
        "title" => "Le Jardin au clair de lune",
        "status" => "draft",
        "role" => "owner",
        "category" => "coding",
        "cover" => "forest",
        "level" => "beginner",
        "modules_count" => 2,
        "lessons_count" => 4,
        "updated_at" => "2026-11-23T10:00:00Z"
      }

      shared = %{
        summary
        | "id" => "p2",
          "title" => "Star Charts",
          "role" => "editor",
          "status" => "submitted"
      }

      view =
        open(
          conn,
          Map.put(member_routes(user_fixture()), {"GET", "/api/projects"}, %{
            "owned" => [summary],
            "shared" => [shared]
          }),
          "/studio"
        )

      assert has_element?(view, "#owned-projects #project-p1", "Le Jardin au clair de lune")
      assert has_element?(view, "#owned-projects #project-p1", "2 modules · 4 lessons")
      assert has_element?(view, "#shared-projects #project-p2", "In review")
      assert has_element?(view, "#shared-projects #project-p2", "Editor")
      refute has_element?(view, "#review-link")
    end

    test "empty, unavailable, and the review link for staff", %{conn: conn} do
      view =
        open(
          conn,
          Map.put(member_routes(user_fixture()), {"GET", "/api/projects"}, %{
            "owned" => [],
            "shared" => []
          }),
          "/studio"
        )

      assert has_element?(view, "#no-projects")

      moderator = user_fixture(%{"role" => "moderator"})

      view =
        open(
          conn,
          Map.put(member_routes(moderator), {"GET", "/api/projects"}, :unavailable),
          "/studio"
        )

      assert has_element?(view, "#projects-unavailable")
      assert has_element?(view, "#review-link")
    end

    test "/studio/new creates the project from its brief, then opens the outline", %{conn: conn} do
      routes =
        Map.put(
          member_routes(user_fixture()),
          {"POST", "/api/projects"},
          {201, %{"project" => %{"id" => "p9"}}}
        )

      view = open(conn, routes, "/studio/new")

      view
      |> form("#new-project-form",
        brief: %{
          "title" => "Star Charts",
          "objectives" => "Name three stars\n\nFind the north",
          "duration_minutes" => "40",
          "category" => "science"
        }
      )
      |> render_submit()

      assert_received {:api, %{method: "POST", path: "/api/projects", body: body}}

      assert %{
               "title" => "Star Charts",
               "objectives" => ["Name three stars", "Find the north"],
               "duration_minutes" => 40,
               "category" => "science"
             } = body

      assert_redirect(view, "/studio/p9?step=outline")
    end

    test "/studio/new shows the validation errors of the studio", %{conn: conn} do
      routes =
        Map.put(
          member_routes(user_fixture()),
          {"POST", "/api/projects"},
          {422, %{"error" => "invalid", "errors" => %{"title" => ["can't be blank"]}}}
        )

      view = open(conn, routes, "/studio/new")
      html = view |> form("#new-project-form", brief: %{"title" => " "}) |> render_submit()
      assert html =~ "can&#39;t be blank"
    end
  end

  describe "/studio/credits" do
    test "balance, monthly allocation, ledger and generation history, refreshed in real time", %{
      conn: conn
    } do
      user = user_fixture()

      history = %{
        "entries" => [
          generation(%{
            "status" => "succeeded",
            "credits" => "consumed",
            "project_title" => "Le Jardin au clair de lune"
          })
        ],
        "page" => 1,
        "total_pages" => 1,
        "total" => 1
      }

      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/credits"} => credits(),
          {"GET", "/api/me/generations"} => history
        })

      view = open(conn, routes, "/studio/credits")

      assert has_element?(view, "#credit-balance", "293")

      assert has_element?(
               view,
               "#credits-summary",
               "credits left of 300 this month (Premium plan)"
             )

      assert has_element?(view, "#entry-e2", "Reserved")
      assert has_element?(view, "#entry-e2", "Outline")
      assert has_element?(view, "#entry-e2", "-2")
      assert has_element?(view, "#entry-e1", "Monthly allocation")
      assert has_element?(view, "#history-g1", "Le Jardin au clair de lune")
      assert has_element?(view, "#history-g1", "credits used")

      stub_api(Map.put(routes, {"GET", "/api/me/credits"}, credits(%{"balance" => 281})))
      send(view.pid, {:credits_changed, user["id"], 281})
      assert has_element?(view, "#credit-balance", "281")
    end

    test "billing unreachable", %{conn: conn} do
      routes =
        Map.merge(member_routes(user_fixture()), %{
          {"GET", "/api/me/credits"} => :unavailable,
          {"GET", "/api/me/generations"} => :unavailable
        })

      view = open(conn, routes, "/studio/credits")
      assert has_element?(view, "#credits-unavailable")
    end
  end

  describe "/studio/review" do
    setup do
      snapshot = %{
        "brief" => %{"objectives" => ["Read a loop"]},
        "modules" => [
          %{
            "id" => "m1",
            "title" => "Seeds",
            "lessons" => [
              lesson("l2", "exercise", "Counting Petals", %{
                "question" => "Q?",
                "choices" => ["1, 2, 3", "0, 1, 2"],
                "answer" => 1,
                "explanation" => "E"
              })
            ]
          }
        ],
        "images" => []
      }

      review = %{
        "project" =>
          studio_project(%{"status" => "submitted", "submitted_at" => "2026-11-23T09:00:00Z"}),
        "version" => %{
          "id" => "v3",
          "number" => 3,
          "note" => "Submitted for review",
          "source" => "submission",
          "snapshot" => snapshot
        },
        "checks" => [%{"key" => "structure", "ok" => true, "issues" => []}],
        "attestations" => %{
          "accuracy" => true,
          "safety" => true,
          "accessibility" => true,
          "valid" => true
        }
      }

      {:ok,
       review: review,
       theo:
         user_fixture(%{"id" => "theo-1", "role" => "moderator", "username" => "theo_garnier"})}
    end

    test "staff queue with the authors' names; members are refused", %{
      conn: conn,
      theo: theo,
      review: review
    } do
      routes =
        Map.merge(member_routes(theo), %{
          {"GET", "/api/moderation/queue"} => %{"projects" => [review["project"]]},
          {"GET", "/api/users"} => %{
            "users" => [
              %{"id" => "owner-1", "username" => "lea_moreau", "display_name" => "Léa Moreau"}
            ]
          }
        })

      view = open(conn, routes, "/studio/review")
      assert has_element?(view, "#queued-p1", "Le Jardin au clair de lune")
      assert has_element?(view, "#queued-p1", "by Léa Moreau")

      # a member: the themed 403 page, before any call to studio (same rule as /admin)
      stub_api(member_routes(user_fixture()))
      flush = fn flush -> receive do: ({:api, _} -> flush.(flush)), after: (0 -> :ok) end
      flush.(flush)

      assert_error_sent(403, fn -> conn |> log_in() |> get(~p"/studio/review") end)
      refute_received {:api, %{path: "/api/moderation/queue"}}

      # staff, but studio refuses (role changed meanwhile): an inline state
      view =
        open(
          conn,
          Map.put(
            member_routes(MysticWeb.AdminFixtures.staff("moderator")),
            {"GET", "/api/moderation/queue"},
            {403, %{"error" => "forbidden"}}
          ),
          "/studio/review"
        )

      assert has_element?(view, "#review-forbidden")
    end

    test "the submitted snapshot with the correct answer; approve, or reject with a reason", %{
      conn: conn,
      theo: theo,
      review: review
    } do
      routes =
        Map.merge(member_routes(theo), %{
          {"GET", "/api/moderation/projects/p1"} => review,
          {"POST", "/api/moderation/projects/p1/approve"} => %{"project" => review["project"]},
          {"POST", "/api/moderation/projects/p1/reject"} => fn _conn, body ->
            if String.length(String.trim(body["reason"])) < 3,
              do:
                {422,
                 %{
                   "error" => "invalid",
                   "errors" => %{"reason" => ["should be 3 to 1000 character(s)"]}
                 }},
              else: %{"project" => review["project"]}
          end
        })

      view = open(conn, routes, "/studio/review/p1")
      assert has_element?(view, "#snapshot", "Counting Petals")
      assert has_element?(view, "#answer-l2", "Correct answer: 0, 1, 2")
      assert has_element?(view, "#review-declarations", "Declared by the author")

      view |> element("#approve") |> render_click()
      assert_received {:api, %{method: "POST", path: "/api/moderation/projects/p1/approve"}}

      html = view |> form("#reject-form", %{"reason" => " "}) |> render_submit()
      assert html =~ "should be 3 to 1000 character(s)"

      view |> form("#reject-form", %{"reason" => "Please describe the image."}) |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/moderation/projects/p1/reject",
                         body: %{"reason" => "Please describe the image."}
                       }}

      assert_redirect(view, "/studio/review")
    end

    test "approved: the import status follows in real time", %{
      conn: conn,
      theo: theo,
      review: review
    } do
      approved =
        put_in(
          review,
          ["project"],
          studio_project(%{
            "status" => "approved",
            "publication" => %{
              "slug" => nil,
              "message" =>
                "The learning catalog is unavailable right now. It will be retried automatically."
            }
          })
        )

      view =
        open(
          conn,
          Map.put(member_routes(theo), {"GET", "/api/moderation/projects/p1"}, approved),
          "/studio/review/p1"
        )

      assert has_element?(view, "#import-status", "unavailable right now")
      assert has_element?(view, "#retry-import")

      stub_api(
        Map.put(
          member_routes(theo),
          {"GET", "/api/moderation/projects/p1"},
          {404, %{"error" => "not_found"}}
        )
      )

      send(view.pid, {:studio_project, "p1", %{"by" => nil, "status" => "published"}})
      assert has_element?(view, "#review-gone")
    end
  end

  describe "/membership" do
    test "shows the AI credits of the month and links to their history", %{conn: conn} do
      user = user_fixture()

      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/plans"} => plans(),
          {"GET", "/api/me/billing"} => billing(user["id"]),
          {"GET", "/api/me/credits"} => credits()
        })

      view = open(conn, routes, "/membership")

      assert has_element?(view, "#ai-credits-balance", "293")
      assert has_element?(view, "#ai-credits", "of 300 credits left this month")
      assert has_element?(view, "#ai-credits-history[href='/studio/credits']")

      stub_api(Map.put(routes, {"GET", "/api/me/credits"}, credits(%{"balance" => 12})))
      send(view.pid, {:credits_changed, user["id"], 12})
      assert has_element?(view, "#ai-credits-balance", "12")
    end

    test "credits unavailable do not break the page", %{conn: conn} do
      user = user_fixture()

      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/plans"} => plans(),
          {"GET", "/api/me/billing"} => billing(user["id"]),
          {"GET", "/api/me/credits"} => :unavailable
        })

      view = open(conn, routes, "/membership")
      assert has_element?(view, "#ai-credits", "Temporarily unavailable")
      assert has_element?(view, "#plan-free", "Current plan")
    end
  end

  describe "image proxy" do
    test "members get the bytes with a safe content type; anything else is a 404", %{conn: conn} do
      user = user_fixture()
      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 9, 9>>

      Req.Test.stub(MlShared.Client, fn conn ->
        case conn.request_path do
          "/api/sessions/current" ->
            Req.Test.json(conn, %{"user" => user})

          "/api/projects/p1/images/i1" ->
            conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, png)

          _ ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})
        end
      end)

      served = conn |> log_in() |> get("/studio/p1/images/i1")
      assert response(served, 200) == png
      assert get_resp_header(served, "content-type") == ["image/png"]
      assert get_resp_header(served, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(served, "cache-control") == ["private, max-age=300"]

      assert conn |> log_in() |> get("/studio/p1/images/other") |> response(404)
      assert build_conn() |> get("/studio/p1/images/i1") |> response(404)
    end
  end
end
