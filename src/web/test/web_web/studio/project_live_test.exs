defmodule MysticWeb.Studio.ProjectLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.StudioFixtures

  setup do
    user = user_fixture(%{"id" => "owner-1"})
    project = studio_project()
    {:ok, user: user, project: project, routes: studio_routes(member_routes(user), project)}
  end

  defp open(conn, routes, path \\ "/studio/p1") do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(path)
    view
  end

  test "subscribes to the project topic only after the studio granted access, then loads", %{
    conn: conn,
    routes: routes,
    project: project
  } do
    test = self()

    routes =
      Map.put(routes, {"GET", "/api/projects/p1/generations"}, fn _conn, _ ->
        subscribed =
          Enum.any?(Registry.lookup(MlShared.PubSub, "studio:project:p1"), fn {pid, _} ->
            pid == self()
          end)

        send(test, {:generations_loaded, subscribed})
        %{"generations" => []}
      end)

    view = open(conn, routes)
    assert_received {:generations_loaded, false}
    assert_received {:generations_loaded, true}
    assert has_element?(view, "#project-title", project["title"])
    assert has_element?(view, "#studio-steps a", "Publish")
    assert has_element?(view, "#credit-balance", "293 AI credits left this month")
  end

  test "a project of somebody else is a 404 page", %{conn: conn, routes: routes} do
    stub_api(Map.put(routes, {"GET", "/api/projects/p1"}, {404, %{"error" => "not_found"}}))
    assert_raise MysticWeb.NotFoundError, fn -> conn |> log_in() |> live("/studio/p1") end
  end

  test "brief autosave: PATCH with the lock version, « Saved at … UTC »; conflict → the author chooses",
       %{conn: conn, routes: routes, project: project} do
    saved =
      Map.take(project, ~w(id title))
      |> Map.merge(%{"lock_version" => 5, "updated_at" => "2026-11-23T14:05:32Z"})

    view = open(conn, Map.put(routes, {"PATCH", "/api/projects/p1"}, %{"project" => saved}))

    view
    |> form("#brief-form",
      brief: %{"title" => "Moonwillow revised", "objectives" => "Read a loop\nWrite a loop\n"}
    )
    |> render_change()

    assert_received {:api, %{method: "PATCH", path: "/api/projects/p1", body: body}}

    assert %{
             "lock_version" => 4,
             "title" => "Moonwillow revised",
             "objectives" => ["Read a loop", "Write a loop"],
             "duration_minutes" => 25
           } = body

    assert has_element?(view, "#brief-saved", "Saved at 14:05:32 UTC")

    current = Map.merge(saved, %{"lock_version" => 7, "title" => "Their title"})

    stub_api(
      Map.put(
        routes,
        {"PATCH", "/api/projects/p1"},
        {409, %{"error" => "conflict", "current" => current}}
      )
    )

    view |> form("#brief-form", brief: %{"title" => "Mine"}) |> render_change()
    assert has_element?(view, "#conflict", "A collaborator saved this first")

    stub_api(
      Map.put(routes, {"PATCH", "/api/projects/p1"}, %{
        "project" => %{saved | "lock_version" => 8}
      })
    )

    view |> element("#keep-mine") |> render_click()
    assert_received {:api, %{method: "PATCH", body: %{"title" => "Mine", "lock_version" => 7}}}
    refute has_element?(view, "#conflict")
  end

  test "outline: keyboard reordering keeps the focus and announces the new position", %{
    conn: conn,
    routes: routes
  } do
    view =
      open(
        conn,
        Map.put(routes, {"PUT", "/api/projects/p1/modules/order"}, %{"modules" => []}),
        "/studio/p1?step=outline"
      )

    assert has_element?(view, "#module-m1-up[disabled]")
    view |> element("#module-m1-down") |> render_click()

    assert_received {:api,
                     %{
                       method: "PUT",
                       path: "/api/projects/p1/modules/order",
                       body: %{"module_ids" => ["m2", "m1"]}
                     }}

    # moved to the bottom: its « down » button is disabled, the focus goes to « up »
    assert_push_event(view, "studio:focus", %{id: "module-m1-up"})

    assert has_element?(
             view,
             "#studio-announce",
             "“Seeds of Moonlight” moved to position 2 of 2."
           )
  end

  test "AI: the cost is confirmed before anything starts, statuses follow in real time", %{
    conn: conn,
    routes: routes
  } do
    routes =
      Map.merge(routes, %{
        {"POST", "/api/projects/p1/generations"} => {202, %{"generation" => generation()}},
        {"POST", "/api/generations/g1/cancel"} => %{
          "generation" => generation(%{"status" => "cancelled", "credits" => "released"})
        }
      })

    view = open(conn, routes, "/studio/p1?step=outline")
    assert has_element?(view, "#demo-mode", "DEMO MODE — not a real AI")

    view |> element("#ai-outline") |> render_click()
    refute_received {:api, %{method: "POST", path: "/api/projects/p1/generations"}}
    assert has_element?(view, "#confirm-cost", "This uses 2 credits.")
    assert has_element?(view, "#confirm-cost", "You have 293 left this month.")

    view |> form("#confirm-form", %{"brief" => "Moon gardens"}) |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/projects/p1/generations",
                       body: %{
                         "kind" => "outline",
                         "brief" => "Moon gardens",
                         "confirm_cost" => 2
                       }
                     }}

    assert has_element?(view, "#generation-g1-status", "Queued")

    send(view.pid, {:studio_generation, "p1", generation(%{"status" => "running"})})
    assert has_element?(view, "#generation-g1-status", "Generating…")

    view |> element("#cancel-g1") |> render_click()
    assert has_element?(view, "#generation-g1-status", "Cancelled")
    assert render(view) =~ "credits refunded"

    result = %{
      "modules" => [
        %{"title" => "Demo module 1: Moon", "lessons" => [%{"title" => "x", "kind" => "story"}]}
      ]
    }

    send(
      view.pid,
      {:studio_generation, "p1",
       generation(%{
         "id" => "g2",
         "status" => "succeeded",
         "credits" => "consumed",
         "result" => result
       })}
    )

    assert has_element?(view, "#generation-g2", "Demo module 1: Moon")
    assert has_element?(view, "#apply-g2")
  end

  test "AI refusals are explained: not enough credits, VIP only", %{conn: conn, routes: routes} do
    stub = fn body -> Map.put(routes, {"POST", "/api/projects/p1/generations"}, body) end

    view =
      open(
        conn,
        stub.({402, %{"error" => "insufficient_credits", "balance" => 1}}),
        "/studio/p1?step=outline"
      )

    view |> element("#ai-outline") |> render_click()
    view |> form("#confirm-form", %{"brief" => "x"}) |> render_submit()
    assert render(view) =~ "Not enough AI credits: 1 left this month."

    stub_api(stub.({402, %{"error" => "vip_required"}}))
    view |> element("#ai-outline") |> render_click()
    view |> form("#confirm-form", %{"brief" => "x"}) |> render_submit()
    assert render(view) =~ "Image generation is part of the VIP plan."
  end

  test "build: lesson editor saves the quiz content; images upload with their alt text", %{
    conn: conn,
    routes: routes
  } do
    quiz = %{
      "lesson" =>
        lesson("l2", "exercise", "Counting Petals", %{
          "question" => "Q?",
          "choices" => ["a", "b"],
          "answer" => 0,
          "explanation" => "E"
        })
    }

    routes =
      Map.merge(routes, %{
        {"PATCH", "/api/projects/p1/lessons/l2"} => quiz,
        {"POST", "/api/projects/p1/images"} => {201, %{"image" => %{}}}
      })

    view = open(conn, routes, "/studio/p1?step=build&lesson=l2")

    view
    |> form("#lesson-form",
      lesson: %{
        "question" => "Q?",
        "choices" => ["a", "b"],
        "answer" => "0",
        "explanation" => "E"
      }
    )
    |> render_change()

    assert_received {:api, %{method: "PATCH", path: "/api/projects/p1/lessons/l2", body: body}}

    assert %{
             "lock_version" => 3,
             "content" => %{
               "question" => "Q?",
               "choices" => ["a", "b"],
               "answer" => 0,
               "explanation" => "E"
             }
           } = body

    assert has_element?(view, "#lesson-saved", "Saved at 10:00:00 UTC")

    png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3>>

    image =
      file_input(view, "#upload-form", :image, [
        %{name: "leaf.png", content: png, type: "image/png"}
      ])

    render_upload(image, "leaf.png")

    view
    |> form("#upload-form", %{"alt" => "A silver leaf", "lesson_id" => "l2"})
    |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/projects/p1/images",
                       body: %{"alt" => "A silver leaf", "lesson_id" => "l2", "data" => data}
                     }}

    assert Base.decode64!(data) == png
  end

  test "review: checks explained, learner preview without the answer, versions restore", %{
    conn: conn,
    routes: routes,
    project: project
  } do
    checks = %{
      "ready" => false,
      "attestations" => nil,
      "checks" => [
        %{"key" => "structure", "ok" => true, "issues" => []},
        %{
          "key" => "quizzes",
          "ok" => false,
          "issues" => [
            %{
              "code" => "quiz_answer",
              "module" => 1,
              "lesson" => 2,
              "title" => "Counting Petals",
              "field" => nil,
              "image" => nil
            }
          ]
        }
      ]
    }

    versions = %{
      "versions" => [
        %{
          "id" => "v1",
          "number" => 1,
          "note" => "First outline",
          "source" => "manual",
          "author_id" => "owner-1",
          "inserted_at" => "2026-11-20T10:00:00Z"
        }
      ]
    }

    routes =
      Map.merge(routes, %{
        {"GET", "/api/projects/p1/checks"} => checks,
        {"GET", "/api/projects/p1/versions"} => versions,
        {"POST", "/api/projects/p1/versions/v1/restore"} =>
          {201, %{"version" => %{"number" => 2}, "project" => project}}
      })

    view = open(conn, routes, "/studio/p1?step=review")

    assert has_element?(
             view,
             "#check-quizzes",
             "Module 1, lesson 2 “Counting Petals”: choose the correct answer."
           )

    assert has_element?(view, "#preview-l2", "What does range(3) produce?")
    refute has_element?(view, "#preview-l2", "It starts at 0.")
    assert has_element?(view, "#attestations", "declarations made by the author")

    view |> element("#restore-1") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/projects/p1/versions/v1/restore"}}
    assert render(view) =~ "Restored: the content is now version 2."
  end

  test "publish: submission only when checks pass and declarations are valid", %{conn: conn} do
    ready = %{"ready" => true, "checks" => [], "attestations" => %{"valid" => true}}

    project =
      studio_project(%{
        "attestations" => %{
          "accuracy" => true,
          "safety" => true,
          "accessibility" => true,
          "valid" => true
        }
      })

    routes =
      Map.merge(studio_routes(member_routes(user_fixture(%{"id" => "owner-1"})), project), %{
        {"GET", "/api/projects/p1/checks"} => ready,
        {"POST", "/api/projects/p1/submit"} => %{
          "project" => %{project | "status" => "submitted"}
        }
      })

    view = open(conn, routes, "/studio/p1?step=publish")
    refute has_element?(view, "#submit-project[disabled]")
    view |> element("#submit-project") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/projects/p1/submit"}}
    assert render(view) =~ "Submitted: a moderator will review it."

    stub_api(Map.put(routes, {"GET", "/api/projects/p1/checks"}, %{ready | "ready" => false}))
    {:ok, view, _} = conn |> log_in() |> live("/studio/p1?step=publish")
    assert has_element?(view, "#submit-project[disabled]")
    assert has_element?(view, "#submit-blockers")
  end

  test "a viewer reads without editing tools; collaborator changes follow in real time", %{
    conn: conn
  } do
    user = user_fixture(%{"id" => "viewer-1"})
    project = studio_project(%{"role" => "viewer"})
    view = open(conn, studio_routes(member_routes(user), project), "/studio/p1?step=outline")

    assert has_element?(view, "#viewer-notice")
    refute has_element?(view, "#ai-outline")
    refute has_element?(view, "#module-m1-down")
    assert has_element?(view, "#module-title-m1[disabled]")

    stub_api(studio_routes(member_routes(user), %{project | "title" => "Renamed by Léa"}))

    send(
      view.pid,
      {:studio_project, "p1", %{"by" => "owner-1", "revision" => 10, "status" => "draft"}}
    )

    assert has_element?(view, "#project-title", "Renamed by Léa")
  end

  test "owner invites a collaborator by username", %{conn: conn, routes: routes} do
    view =
      open(
        conn,
        Map.put(
          routes,
          {"POST", "/api/projects/p1/collaborators"},
          {403, %{"error" => "blocked"}}
        )
      )

    assert has_element?(view, "#collaborator-ines-1", "@ines_petit")

    view
    |> form("#invite-form", %{"username" => "hugo_bernard", "role" => "viewer"})
    |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/projects/p1/collaborators",
                       body: %{"username" => "hugo_bernard", "role" => "viewer"}
                     }}

    assert render(view) =~ "This member can&#39;t be invited."
  end
end
