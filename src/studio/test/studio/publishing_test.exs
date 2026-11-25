defmodule MlStudio.PublishingTest do
  use MlStudio.DataCase, async: true
  alias MlStudio.{Projects, Publishing}
  alias MlStudio.Projects.{Lesson, Project, Version}
  alias MlStudio.Publishing.{Checks, ImportWorker}

  @theo "00000000-0000-4000-8000-000000000005"

  setup do
    owner = uuid()
    {:ok, owner: owner, project: project_fixture(owner)}
  end

  defp staff(user_id, role \\ "moderator"),
    do: %{
      {"GET", "/api/internal/users/#{user_id}"} => %{"user" => %{"id" => user_id, "role" => role}},
      {"POST", "/api/internal/audit"} => {201, %{"id" => 1}}
    }

  defp failing(snapshot), do: for(%{"ok" => false, "key" => key} <- Checks.run(snapshot), do: key)

  defp issue_codes(snapshot, key),
    do:
      snapshot
      |> Checks.run()
      |> Enum.find(&(&1["key"] == key))
      |> Map.fetch!("issues")
      |> Enum.map(& &1["code"])

  describe "automatic checks, one by one" do
    setup %{project: project} do
      snapshot = Projects.snapshot(project)
      assert failing(snapshot) == []
      {:ok, snapshot: snapshot}
    end

    defp put_lesson(snapshot, index, fun),
      do: update_in(snapshot, ["modules", Access.at(0), "lessons", Access.at(index)], fun)

    test "structure: at least one module and one lesson per module", %{snapshot: s} do
      assert failing(%{s | "modules" => []}) == ["structure"]
      empty = %{"id" => "m2", "title" => "Empty", "lessons" => []}

      assert issue_codes(Map.update!(s, "modules", &(&1 ++ [empty])), "structure") == [
               "empty_module"
             ]
    end

    test "objectives", %{snapshot: s} do
      assert failing(put_in(s, ["brief", "objectives"], [])) == ["objectives"]

      assert failing(put_in(s, ["brief", "objectives"], [String.duplicate("o", 201)])) == [
               "objectives"
             ]
    end

    test "titles", %{snapshot: s} do
      assert failing(put_in(s, ["brief", "title"], "Hi")) == ["titles"]

      assert failing(put_lesson(s, 0, &Map.put(&1, "title", String.duplicate("t", 121)))) == [
               "titles"
             ]
    end

    test "valid multiple-choice quiz", %{snapshot: s} do
      for content <- [
            %{"answer" => 5},
            %{"choices" => ["Same", "Same"]},
            %{"choices" => ["Only one"], "answer" => 0},
            %{"question" => " "},
            %{"explanation" => ""}
          ] do
        assert failing(
                 put_lesson(s, 1, &Map.update!(&1, "content", fn c -> Map.merge(c, content) end))
               ) == ["quizzes"],
               inspect(content)
      end
    end

    test "GroveScript parameters", %{snapshot: s} do
      for content <- [
            %{"plants" => 1},
            %{"plants" => 11},
            %{"starter" => ""},
            %{"hints" => []},
            %{"hints" => Enum.map(1..6, &"hint #{&1}")}
          ] do
        assert failing(
                 put_lesson(s, 2, &Map.update!(&1, "content", fn c -> Map.merge(c, content) end))
               ) == ["grovescript"],
               inspect(content)
      end
    end

    test "every image has a text alternative", %{snapshot: s} do
      assert failing(Map.put(s, "images", [%{"id" => "i1", "alt" => "  ", "lesson_id" => nil}])) ==
               ["image_alt"]
    end

    test "no HTML nor script", %{snapshot: s} do
      assert failing(put_lesson(s, 0, &Map.put(&1, "body", "Hello <script>alert(1)</script>"))) ==
               ["no_html"]

      assert failing(put_in(s, ["brief", "summary"], "A <b>bold</b> summary")) == ["no_html"]
      # comparisons are not tags
      assert failing(put_lesson(s, 0, &Map.put(&1, "body", "if 2 < 3 then smile"))) == []
    end

    test "lengths", %{snapshot: s} do
      assert failing(put_in(s, ["brief", "summary"], String.duplicate("s", 301))) == ["lengths"]
      assert failing(put_in(s, ["brief", "duration_minutes"], 1)) == ["lengths"]
      assert failing(put_lesson(s, 0, &Map.put(&1, "body", ""))) == ["lengths"]
      assert failing(put_lesson(s, 0, &Map.put(&1, "xp_reward", 500))) == ["lengths"]
    end

    test "only http(s) links", %{snapshot: s} do
      assert failing(put_lesson(s, 0, &Map.put(&1, "body", "See https://example.org/moon"))) == []

      assert failing(put_lesson(s, 0, &Map.put(&1, "body", "Click javascript:alert(1)"))) == [
               "links"
             ]

      assert failing(put_lesson(s, 0, &Map.put(&1, "body", "Get ftp://files.example.org"))) == [
               "links"
             ]
    end
  end

  test "attestations are declarations for one revision: any content change invalidates them", %{
    owner: owner,
    project: p
  } do
    p = attested(p)

    assert {:ok, %{"ready" => true, "attestations" => %{"valid" => true, "accuracy" => true}}} =
             Publishing.checks(owner, p.id)

    lesson = Repo.get_by!(Lesson, project_id: p.id, kind: "story")

    {:ok, _} =
      Projects.update_lesson(owner, p.id, lesson.id, %{
        "lock_version" => lesson.lock_version,
        "body" => "Changed."
      })

    assert {:ok, %{"attestations" => %{"valid" => false}}} = Publishing.checks(owner, p.id)
    assert {:error, :attestations_required} = Publishing.submit(owner, p.id)

    partial = MlStudio.Publishing.attest(owner, p.id, %{"accuracy" => true, "safety" => true})
    assert {:ok, %Project{}} = partial
    assert {:error, :attestations_required} = Publishing.submit(owner, p.id)
  end

  test "submission needs green checks, locks the project and snapshots a version", %{
    owner: owner,
    project: p
  } do
    lesson = Repo.get_by!(Lesson, project_id: p.id, kind: "exercise")

    {:ok, _} =
      Projects.update_lesson(owner, p.id, lesson.id, %{
        "lock_version" => lesson.lock_version,
        "content" => %{"answer" => nil}
      })

    attested(Repo.get!(Project, p.id))

    assert {:error, {:checks_failed, checks}} = Publishing.submit(owner, p.id)

    assert [
             %{
               "key" => "quizzes",
               "issues" => [%{"code" => "quiz_answer", "module" => 1, "lesson" => 2}]
             }
           ] = Enum.reject(checks, & &1["ok"])

    {:ok, _} =
      Projects.update_lesson(owner, p.id, lesson.id, %{
        "lock_version" => lesson.lock_version + 1,
        "content" => %{"answer" => 0}
      })

    attested(Repo.get!(Project, p.id))

    assert {:ok, %Project{status: "submitted", review_version: 1}} =
             Publishing.submit(owner, p.id)

    assert %Version{source: "submission"} = Repo.get_by!(Version, project_id: p.id, number: 1)

    assert {:error, :locked} =
             Projects.update_brief(owner, p.id, %{"title" => "During review", "lock_version" => 1})

    assert {:error, :not_draft} = Publishing.submit(owner, p.id)

    assert {:ok, %Project{status: "draft"}} = Publishing.withdraw(owner, p.id)
  end

  test "staff review: queue and snapshot for staff only, author ≠ reviewer, reject with reason",
       %{owner: owner, project: p} do
    editor = uuid()

    Repo.insert!(%MlStudio.Projects.Collaborator{
      project_id: p.id,
      user_id: editor,
      username: "ines_petit",
      role: "editor",
      invited_by: owner
    })

    {:ok, _} = p |> attested() |> then(&Publishing.submit(owner, &1.id))
    member = uuid()

    stub_services(
      staff(@theo)
      |> Map.merge(staff(owner))
      |> Map.merge(staff(editor, "admin"))
      |> Map.merge(staff(member, "user"))
    )

    assert {:error, :forbidden} = Publishing.queue(member)
    assert {:error, :forbidden} = Publishing.review(member, p.id)
    assert {:ok, [%Project{id: id}]} = Publishing.queue(@theo)
    assert id == p.id

    assert {:ok,
            %{
              version: %Version{number: 1, snapshot: %{"modules" => [_]}},
              checks: checks,
              attestations: %{"valid" => true}
            }} =
             Publishing.review(@theo, p.id)

    assert Checks.ok?(checks)

    # the owner, even with a staff role, and an editor of the project can't review it
    assert {:error, :own_project} = Publishing.approve(owner, p.id)

    assert {:error, :own_project} =
             Publishing.reject(editor, p.id, %{"reason" => "Looks fine to me"})

    assert {:error, {:invalid, %{reason: _}}} = Publishing.reject(@theo, p.id, %{"reason" => " "})

    assert {:ok, %Project{status: "draft", review_reason: "Please add an image description."}} =
             Publishing.reject(@theo, p.id, %{"reason" => "Please add an image description."})

    # a draft is no longer visible to the staff
    assert {:error, :not_found} = Publishing.review(@theo, p.id)

    # the decision is notified (durably, in its transaction) to the owner and the editor, without the title,
    # the reviewer or the reason
    notified =
      for job <- all_enqueued(worker: MlStudio.NotifyWorker),
          job.args["params"]["project_id"] == p.id,
          do: job.args

    assert notified |> Enum.map(& &1["user_id"]) |> Enum.sort() == Enum.sort([owner, editor])

    for n <- notified do
      assert %{
               "category" => "studio",
               "kind" => "review_rejected",
               "dedupe_key" => "project:" <> _
             } = n

      refute Map.has_key?(n, "actor_id")
      refute inspect(n) =~ "image description"
    end

    # the worker delivers to the center and follows its answer
    test = self()

    Req.Test.stub(MlShared.Client, fn conn ->
      send(test, {:center, conn.request_path})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"status" => "created"})
    end)

    assert :ok = perform_job(MlStudio.NotifyWorker, hd(notified))
    assert_received {:center, "/api/internal/notifications"}
  end

  test "staff checks fail closed when accounts is unreachable", %{project: p} do
    stub_services(%{{"GET", "/api/internal/users/#{@theo}"} => :unavailable})
    assert {:error, :accounts_unavailable} = Publishing.approve(@theo, p.id)
  end

  describe "approval → import job into learning" do
    setup %{owner: owner, project: p} do
      {:ok, _} = p |> attested() |> then(&Publishing.submit(owner, &1.id))
      stub_services(staff(@theo))

      assert {:ok, %Project{status: "approved", reviewed_by: @theo}} =
               Publishing.approve(@theo, p.id)

      assert_enqueued(worker: ImportWorker, args: %{project_id: p.id, version: 1})
      :ok
    end

    defp import_route(response),
      do: stub_services(%{{"POST", "/api/internal/adventures/import"} => response})

    test "learning 200: published with the slug; the payload follows the contract", %{project: p} do
      import_route(%{
        "adventure_id" => "a1",
        "slug" => "le-jardin-au-clair-de-lune",
        "version" => 1
      })

      assert :ok = perform_job(ImportWorker, %{project_id: p.id, version: 1})

      assert_received {:service, %{path: "/api/internal/adventures/import", body: body}}
      assert %{"external_id" => external_id, "version" => 1, "adventure" => adventure} = body
      assert external_id == p.id

      assert %{
               "title" => "Le Jardin au clair de lune",
               "difficulty" => "beginner",
               "premium" => false,
               "author_id" => author
             } = adventure

      assert author == p.owner_id

      assert [%{"title" => "Seeds of Moonlight", "lessons" => [story, quiz, coding]}] =
               adventure["chapters"]

      assert %{"kind" => "story", "xp_reward" => 10} = story

      assert %{
               "kind" => "exercise",
               "solution" => 1,
               "explanation" => _,
               "content" => %{"question" => _, "choices" => ["1, 2, 3", "0, 1, 2"]}
             } = quiz

      refute Map.has_key?(quiz["content"], "answer")

      assert %{
               "kind" => "coding",
               "content" => %{"plants" => 4, "starter" => "water(0)\n", "hints" => [_]}
             } = coding

      assert %Project{
               status: "published",
               published_slug: "le-jardin-au-clair-de-lune",
               published_version: 1,
               import_message: nil
             } =
               Repo.get!(Project, p.id)
    end

    test "learning 404 (route not deployed): stays approved, clear message, retried", %{
      project: p
    } do
      import_route({404, %{"error" => "not_found"}})

      assert {:error, :import_not_available} =
               perform_job(ImportWorker, %{project_id: p.id, version: 1})

      assert %Project{status: "approved", import_message: message} = Repo.get!(Project, p.id)
      assert message =~ "HTTP 404"
      assert message =~ "retried automatically"
    end

    test "learning unreachable: stays approved and retried; 422 is final", %{project: p} do
      import_route(:unavailable)

      assert {:error, :learning_unavailable} =
               perform_job(ImportWorker, %{project_id: p.id, version: 1})

      assert %Project{
               status: "approved",
               import_message: "The learning catalog is unavailable" <> _
             } = Repo.get!(Project, p.id)

      import_route(
        {422,
         %{"error" => "invalid", "errors" => %{"chapters" => ["must contain 1 to 20 chapters"]}}}
      )

      assert {:cancel, _} = perform_job(ImportWorker, %{project_id: p.id, version: 1})

      assert %Project{
               status: "approved",
               import_message: "The learning catalog refused the content: chapters" <> _
             } = Repo.get!(Project, p.id)
    end

    test "a replayed job after publication does nothing", %{project: p} do
      import_route(%{
        "adventure_id" => "a1",
        "slug" => "le-jardin-au-clair-de-lune",
        "version" => 1
      })

      :ok = perform_job(ImportWorker, %{project_id: p.id, version: 1})
      :ok = perform_job(ImportWorker, %{project_id: p.id, version: 1})
      assert_received {:service, %{path: "/api/internal/adventures/import"}}
      refute_received {:service, %{path: "/api/internal/adventures/import"}}
    end
  end
end
