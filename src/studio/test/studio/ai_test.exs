defmodule MlStudio.AITest do
  use MlStudioWeb.ConnCase, async: true
  alias MlStudio.AI.{Deterministic, Generation, GenerationWorker, SettleWorker}
  alias MlStudio.Projects.{Lesson, Project}

  setup %{conn: conn} do
    owner = uuid()
    project = project_fixture(owner)
    stub_services(credit_routes())
    {:ok, owner: owner, project: project, me: as_user(conn, owner)}
  end

  defp generate(me, project, params),
    do:
      me
      |> post("/api/projects/#{project.id}/generations", params)
      |> json_response(202)
      |> Map.fetch!("generation")

  defp outline(me, project),
    do:
      generate(me, project, %{
        "kind" => "outline",
        "brief" => "Moon gardens. Night flowers",
        "confirm_cost" => 2
      })

  test "the DEMO provider is deterministic and labelled" do
    request = %{
      kind: "outline",
      brief: "Moon gardens. Night flowers",
      lesson_kind: nil,
      context: nil
    }

    assert {:ok, %{"modules" => [m1, m2]} = out} = Deterministic.generate(request)
    assert {:ok, ^out} = Deterministic.generate(request)
    assert m1["title"] == "Demo module 1: Moon gardens"
    assert m2["title"] == "Demo module 2: Night flowers"

    assert Enum.all?(
             m1["lessons"],
             &String.starts_with?(&1["summary"], "DEMO MODE — not a real AI")
           )

    for kind <- ~w(story exercise coding) do
      assert {:ok, %{"body" => "DEMO MODE — not a real AI" <> _}} =
               Deterministic.generate(%{request | kind: "lesson_draft", lesson_kind: kind})
    end

    assert {:ok, %{data: svg, content_type: "image/svg+xml"}} =
             Deterministic.generate_image(request)

    assert svg =~ "DEMO MODE — not a real AI"
    assert {:ok, %{data: ^svg}} = Deterministic.generate_image(request)
  end

  test "cost confirmed before launch, credits reserved, async run, consumed once, real-time statuses",
       %{me: me, owner: owner, project: p} do
    MlShared.Events.subscribe("studio:project:#{p.id}")
    path = "/api/projects/#{p.id}/generations"

    assert %{"errors" => %{"confirm_cost" => _}} =
             me |> post(path, %{"kind" => "outline", "brief" => "x"}) |> json_response(422)

    assert %{"error" => "cost_mismatch", "cost" => 2} =
             me
             |> post(path, %{"kind" => "outline", "brief" => "x", "confirm_cost" => 1})
             |> json_response(409)

    refute_received {:service, %{path: "/api/internal/credits/reserve"}}

    assert %{
             "id" => id,
             "status" => "pending",
             "cost" => 2,
             "credits" => "reserved",
             "provider" => "demo",
             "demo" => true
           } = outline(me, p)

    ref = "studio:gen:" <> id

    assert_received {:service,
                     %{
                       path: "/api/internal/credits/reserve",
                       body: %{
                         "user_id" => ^owner,
                         "amount" => 2,
                         "ref" => ^ref,
                         "reason" => "outline"
                       }
                     }}

    assert_receive {:studio_generation, _, %{"id" => ^id, "status" => "pending"}}

    assert :ok = perform_job(GenerationWorker, %{generation_id: id})
    assert_receive {:studio_generation, _, %{"status" => "running"}}

    assert_receive {:studio_generation, _,
                    %{"status" => "succeeded", "result" => %{"modules" => [_, _]}}}

    assert_enqueued(worker: SettleWorker, args: %{generation_id: id})

    assert :ok = perform_job(SettleWorker, %{generation_id: id})
    assert :ok = perform_job(SettleWorker, %{generation_id: id})
    assert_received {:service, %{path: "/api/internal/credits/consume", body: %{"ref" => ^ref}}}
    refute_received {:service, %{path: "/api/internal/credits/" <> _}}
    assert %Generation{credits: "consumed", status: "succeeded"} = Repo.get!(Generation, id)

    # a replayed generation job never runs the provider again
    assert :ok = perform_job(GenerationWorker, %{generation_id: id})

    assert %{"generation" => %{"applied_at" => applied}} =
             me |> post("/api/generations/#{id}/apply") |> json_response(200)

    assert applied

    assert %{"error" => "already_applied"} =
             me |> post("/api/generations/#{id}/apply") |> json_response(409)

    assert %{"project" => %{"modules" => [_, %{"title" => "Demo module 1: Read a loop"}, _]}} =
             me |> get("/api/projects/#{p.id}") |> json_response(200)

    assert %{
             "entries" => [%{"id" => ^id, "project_title" => "Le Jardin au clair de lune"}],
             "total" => 1
           } =
             me |> get("/api/me/generations") |> json_response(200)
  end

  test "insufficient credits and billing unreachable: nothing is enqueued", %{me: me, project: p} do
    stub_services(%{
      {"POST", "/api/internal/credits/reserve"} =>
        {402, %{"error" => "insufficient_credits", "balance" => 1}}
    })

    assert %{"error" => "insufficient_credits", "balance" => 1} =
             me
             |> post("/api/projects/#{p.id}/generations", %{
               "kind" => "outline",
               "brief" => "x",
               "confirm_cost" => 2
             })
             |> json_response(402)

    stub_services(%{{"POST", "/api/internal/credits/reserve"} => :unavailable})

    assert %{"error" => "credits_unavailable"} =
             me
             |> post("/api/projects/#{p.id}/generations", %{
               "kind" => "outline",
               "brief" => "x",
               "confirm_cost" => 2
             })
             |> json_response(503)

    refute_enqueued(worker: GenerationWorker)
    assert Repo.aggregate(Generation, :count) == 0
  end

  test "cancellation releases the credits exactly once; a retry is a new reservation", %{
    me: me,
    project: p
  } do
    %{"id" => id} = outline(me, p)

    assert %{"generation" => %{"status" => "cancelled"}} =
             me |> post("/api/generations/#{id}/cancel") |> json_response(200)

    assert %{"error" => "not_cancellable"} =
             me |> post("/api/generations/#{id}/cancel") |> json_response(409)

    # the job finds it cancelled: no provider call, the status stays
    assert :ok = perform_job(GenerationWorker, %{generation_id: id})
    assert %Generation{status: "cancelled", result: nil} = Repo.get!(Generation, id)

    assert :ok = perform_job(SettleWorker, %{generation_id: id})
    assert :ok = perform_job(SettleWorker, %{generation_id: id})

    assert_received {:service,
                     %{
                       path: "/api/internal/credits/release",
                       body: %{"ref" => "studio:gen:" <> ^id}
                     }}

    refute_received {:service, %{path: "/api/internal/credits/release"}}
    assert %Generation{credits: "released"} = Repo.get!(Generation, id)

    assert %{"errors" => %{"confirm_cost" => _}} =
             me |> post("/api/generations/#{id}/retry") |> json_response(422)

    assert %{"generation" => %{"id" => new_id, "retry_of" => ^id, "status" => "pending"}} =
             me
             |> post("/api/generations/#{id}/retry", %{"confirm_cost" => 2})
             |> json_response(202)

    assert new_id != id

    assert_received {:service,
                     %{
                       path: "/api/internal/credits/reserve",
                       body: %{"ref" => "studio:gen:" <> ^new_id}
                     }}
  end

  test "lesson drafts and quiz feedback target a lesson of the project", %{me: me, project: p} do
    quiz = Repo.get_by!(Lesson, project_id: p.id, kind: "exercise")
    story = Repo.get_by!(Lesson, project_id: p.id, kind: "story")
    path = "/api/projects/#{p.id}/generations"

    assert %{"errors" => %{"lesson_id" => ["must be a quiz lesson"]}} =
             me
             |> post(path, %{
               "kind" => "feedback",
               "lesson_id" => story.id,
               "brief" => "x",
               "confirm_cost" => 2
             })
             |> json_response(422)

    assert %{"errors" => %{"lesson_id" => _}} =
             me
             |> post(path, %{
               "kind" => "lesson_draft",
               "lesson_id" => uuid(),
               "brief" => "x",
               "confirm_cost" => 5
             })
             |> json_response(422)

    %{"id" => id} =
      generate(me, p, %{
        "kind" => "lesson_draft",
        "lesson_id" => quiz.id,
        "brief" => "Petals of the moonwillow",
        "confirm_cost" => 5
      })

    :ok = perform_job(GenerationWorker, %{generation_id: id})
    me |> post("/api/generations/#{id}/apply") |> json_response(200)

    assert %Lesson{
             body: "DEMO MODE — not a real AI" <> _,
             content: %{"choices" => [_, _, _, _], "answer" => answer}
           } = lesson = Repo.get!(Lesson, quiz.id)

    assert answer in 0..3
    assert lesson.lock_version == quiz.lock_version + 1
  end

  test "images: VIP plan only; the DEMO image needs an alt text before publishing; a downgrade keeps drafts editable",
       %{me: me, owner: owner, project: p} do
    path = "/api/projects/#{p.id}/generations"

    params = %{
      "kind" => "image",
      "brief" => "A spiral of moonwillow leaves",
      "confirm_cost" => 12
    }

    stub_services(
      Map.put(credit_routes(), {"GET", "/api/entitlements/#{owner}"}, %{"plan" => "premium"})
    )

    assert %{"error" => "vip_required"} = me |> post(path, params) |> json_response(402)
    refute_received {:service, %{path: "/api/internal/credits/reserve"}}

    stub_services(
      Map.put(credit_routes(), {"GET", "/api/entitlements/#{owner}"}, %{"plan" => "vip"})
    )

    %{"id" => id} = generate(me, p, params)
    :ok = perform_job(GenerationWorker, %{generation_id: id})

    assert %Generation{status: "succeeded", result: %{"image_id" => image_id}} =
             Repo.get!(Generation, id)

    assert %{
             "project" => %{
               "images" => [
                 %{
                   "id" => ^image_id,
                   "source" => "demo",
                   "alt" => "",
                   "content_type" => "image/svg+xml"
                 }
               ]
             }
           } =
             me |> get("/api/projects/#{p.id}") |> json_response(200)

    assert %{"checks" => checks} = me |> get("/api/projects/#{p.id}/checks") |> json_response(200)

    assert [%{"key" => "image_alt", "issues" => [%{"image" => ^image_id}]}] =
             Enum.reject(checks, & &1["ok"])

    assert me |> get("/api/projects/#{p.id}/images/#{image_id}") |> response(200) =~ "DEMO MODE"

    # downgraded to free: every draft stays editable by hand, only the VIP generation is refused
    stub_services(
      Map.put(credit_routes(), {"GET", "/api/entitlements/#{owner}"}, %{"plan" => "free"})
    )

    assert %{"image" => %{"alt" => "Spiral of leaves"}} =
             me
             |> patch("/api/projects/#{p.id}/images/#{image_id}", %{"alt" => "Spiral of leaves"})
             |> json_response(200)

    assert %{"project" => %{"title" => "Still mine"}} =
             me
             |> patch("/api/projects/#{p.id}", %{
               "title" => "Still mine",
               "lock_version" => Repo.get!(Project, p.id).lock_version
             })
             |> json_response(200)

    assert %{"ready" => true} = me |> get("/api/projects/#{p.id}/checks") |> json_response(200)
    assert %{"error" => "vip_required"} = me |> post(path, params) |> json_response(402)
  end

  test "viewers and locked projects can't generate; consent setting and provider info", %{
    conn: conn,
    me: me,
    owner: owner,
    project: p
  } do
    viewer = uuid()

    Repo.insert!(%MlStudio.Projects.Collaborator{
      project_id: p.id,
      user_id: viewer,
      username: "hugo_bernard",
      role: "viewer",
      invited_by: owner
    })

    assert %{"error" => "forbidden"} =
             conn
             |> as_user(viewer)
             |> post("/api/projects/#{p.id}/generations", %{
               "kind" => "outline",
               "brief" => "x",
               "confirm_cost" => 2
             })
             |> json_response(403)

    assert %{
             "provider" => "demo",
             "demo" => true,
             "label" => "DEMO MODE — not a real AI",
             "configured" => true,
             "image_generation" => true,
             "costs" => %{"outline" => 2, "lesson_draft" => 5, "feedback" => 2, "image" => 12},
             "share_drafts_with_ai" => false
           } =
             me |> get("/api/ai") |> json_response(200)

    assert %{"share_drafts_with_ai" => true} =
             me
             |> put("/api/me/ai-settings", %{"share_drafts_with_ai" => true})
             |> json_response(200)

    assert %{"share_drafts_with_ai" => true} =
             me |> get("/api/me/ai-settings") |> json_response(200)

    assert %{"error" => "invalid"} =
             me
             |> put("/api/me/ai-settings", %{"share_drafts_with_ai" => "yes"})
             |> json_response(422)

    Repo.update_all(from(x in Project, where: x.id == ^p.id), set: [status: "submitted"])

    assert %{"error" => "locked"} =
             me
             |> post("/api/projects/#{p.id}/generations", %{
               "kind" => "outline",
               "brief" => "x",
               "confirm_cost" => 2
             })
             |> json_response(409)
  end
end
