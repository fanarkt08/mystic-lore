defmodule MlStudioWeb.ProjectsApiTest do
  use MlStudioWeb.ConnCase, async: true
  alias MlStudio.Projects.{Lesson, Version}

  setup %{conn: conn} do
    owner = uuid()
    project = project_fixture(owner)
    {:ok, conn: conn, owner: owner, project: project, me: as_user(conn, owner)}
  end

  defp staff(role),
    do: %{"user" => %{"id" => uuid(), "username" => "theo_garnier", "role" => role}}

  test "health, token required, JSON 404", %{conn: conn, project: p} do
    assert %{"status" => "ok"} = conn |> get("/healthz") |> json_response(200)

    assert %{"error" => "unauthorized"} =
             conn |> get("/api/projects/#{p.id}") |> json_response(401)

    service =
      put_req_header(conn, "authorization", "Bearer " <> MlShared.InternalToken.sign("web"))

    assert %{"error" => "unauthorized"} = service |> get("/api/projects") |> json_response(401)
    assert %{"error" => "not_found"} = conn |> get("/nope") |> json_response(404)
  end

  test "create, list (owned + shared), show the full project", %{conn: conn, me: me} do
    assert %{
             "project" => %{
               "id" => id,
               "title" => "Star Charts",
               "status" => "draft",
               "role" => "owner",
               "lock_version" => 1,
               "modules" => []
             }
           } =
             me
             |> post("/api/projects", %{"title" => "Star Charts", "category" => "science"})
             |> json_response(201)

    assert %{"error" => "invalid", "errors" => %{"title" => _}} =
             me |> post("/api/projects", %{"title" => " "}) |> json_response(422)

    assert %{"owned" => owned, "shared" => []} = me |> get("/api/projects") |> json_response(200)
    assert %{"lessons_count" => 0, "role" => "owner"} = Enum.find(owned, &(&1["id"] == id))

    assert %{"modules_count" => 1, "lessons_count" => 3} =
             Enum.find(owned, &(&1["title"] == "Le Jardin au clair de lune"))

    other = as_user(conn, uuid())
    assert %{"owned" => [], "shared" => []} = other |> get("/api/projects") |> json_response(200)
  end

  test "IDOR: nobody else sees or edits a draft, moderators and admins included", %{
    conn: conn,
    project: p
  } do
    [module] = Repo.preload(p, :modules).modules
    lesson = Repo.one!(from l in Lesson, where: l.project_id == ^p.id, limit: 1)

    {:ok, image} =
      MlStudio.Images.upload(p.owner_id, p.id, %{
        "data" => Base.encode64(png()),
        "alt" => "A leaf"
      })

    for role <- ["user", "moderator", "admin"] do
      stranger_id = uuid()
      stub_services(%{{"GET", "/api/internal/users/#{stranger_id}"} => staff(role)})
      stranger = as_user(conn, stranger_id)

      for {method, path} <-
            [
              {:get, "/api/projects/#{p.id}"},
              {:patch, "/api/projects/#{p.id}"},
              {:delete, "/api/projects/#{p.id}"},
              {:post, "/api/projects/#{p.id}/modules"},
              {:patch, "/api/projects/#{p.id}/modules/#{module.id}"},
              {:patch, "/api/projects/#{p.id}/lessons/#{lesson.id}"},
              {:get, "/api/projects/#{p.id}/versions"},
              {:get, "/api/projects/#{p.id}/checks"},
              {:get, "/api/projects/#{p.id}/generations"},
              {:get, "/api/projects/#{p.id}/images/#{image.id}"},
              {:post, "/api/projects/#{p.id}/submit"}
            ] ++ if(role == "user", do: [], else: [{:get, "/api/moderation/projects/#{p.id}"}]) do
        assert %{"error" => "not_found"} =
                 stranger
                 |> dispatch(@endpoint, method, path, %{"title" => "Mine", "lock_version" => 1})
                 |> json_response(404),
               "#{role} #{method} #{path}"
      end
    end

    # a member who is not staff is refused the review routes themselves
    member = uuid()
    stub_services(%{{"GET", "/api/internal/users/#{member}"} => staff("user")})

    assert %{"error" => "forbidden"} =
             conn
             |> as_user(member)
             |> get("/api/moderation/projects/#{p.id}")
             |> json_response(403)

    assert Repo.get!(MlStudio.Projects.Project, p.id).title == "Le Jardin au clair de lune"
  end

  test "collaborators: invited by username, editor edits, viewer reads, blocks refused", %{
    conn: conn,
    me: me,
    project: p,
    owner: owner
  } do
    ines = uuid()
    hugo = uuid()

    stub_services(%{
      {"GET", "/api/users/by-username/ines_petit"} => %{
        "user" => %{"id" => ines, "username" => "ines_petit"}
      },
      {"GET", "/api/users/by-username/hugo_bernard"} => %{
        "user" => %{"id" => hugo, "username" => "hugo_bernard"}
      },
      {"GET", "/api/internal/relationship"} => fn conn, _ ->
        %{"friends" => false, "blocked" => conn.query_params["b"] == hugo}
      end
    })

    assert %{
             "collaborator" => %{
               "user_id" => ^ines,
               "username" => "ines_petit",
               "role" => "viewer"
             }
           } =
             me
             |> post("/api/projects/#{p.id}/collaborators", %{
               "username" => "@Ines_Petit",
               "role" => "viewer"
             })
             |> json_response(201)

    assert_received {:service,
                     %{path: "/api/internal/relationship", query: %{"a" => ^owner, "b" => ^ines}}}

    assert %{"error" => "already_collaborator"} =
             me
             |> post("/api/projects/#{p.id}/collaborators", %{"username" => "ines_petit"})
             |> json_response(409)

    assert %{"error" => "blocked"} =
             me
             |> post("/api/projects/#{p.id}/collaborators", %{"username" => "hugo_bernard"})
             |> json_response(403)

    assert %{"error" => "user_not_found"} =
             me
             |> post("/api/projects/#{p.id}/collaborators", %{"username" => "nobody_here"})
             |> json_response(404)

    viewer = as_user(conn, ines)

    assert %{"project" => %{"role" => "viewer"}} =
             viewer |> get("/api/projects/#{p.id}") |> json_response(200)

    assert %{"shared" => [%{"role" => "viewer"}]} =
             viewer |> get("/api/projects") |> json_response(200)

    assert %{"error" => "forbidden"} =
             viewer
             |> patch("/api/projects/#{p.id}", %{"title" => "Hijack", "lock_version" => 1})
             |> json_response(403)

    assert %{"error" => "forbidden"} =
             viewer
             |> post("/api/projects/#{p.id}/collaborators", %{"username" => "hugo_bernard"})
             |> json_response(403)

    assert %{"collaborator" => %{"role" => "editor"}} =
             me
             |> patch("/api/projects/#{p.id}/collaborators/#{ines}", %{"role" => "editor"})
             |> json_response(200)

    assert %{"project" => %{"title" => "Moonwillow, revised"}} =
             viewer
             |> patch("/api/projects/#{p.id}", %{
               "title" => "Moonwillow, revised",
               "lock_version" => 1
             })
             |> json_response(200)

    # a collaborator may leave
    assert viewer |> delete("/api/projects/#{p.id}/collaborators/#{ines}") |> response(204)

    assert %{"error" => "not_found"} =
             viewer |> get("/api/projects/#{p.id}") |> json_response(404)

    stub_services(%{
      {"GET", "/api/users/by-username/ines_petit"} => %{
        "user" => %{"id" => ines, "username" => "ines_petit"}
      },
      {"GET", "/api/internal/relationship"} => :unavailable
    })

    assert %{"error" => "social_unavailable"} =
             me
             |> post("/api/projects/#{p.id}/collaborators", %{"username" => "ines_petit"})
             |> json_response(503)
  end

  test "autosave: optimistic lock per item, conflict returns the current version", %{
    me: me,
    project: p
  } do
    lesson = Repo.one!(from l in Lesson, where: l.project_id == ^p.id and l.kind == "story")
    v = lesson.lock_version

    assert %{"lesson" => %{"body" => "First", "lock_version" => saved}} =
             me
             |> patch("/api/projects/#{p.id}/lessons/#{lesson.id}", %{
               "lock_version" => v,
               "body" => "First"
             })
             |> json_response(200)

    assert saved == v + 1

    # the second collaborator still edits version v
    assert %{"error" => "conflict", "current" => %{"body" => "First", "lock_version" => ^saved}} =
             me
             |> patch("/api/projects/#{p.id}/lessons/#{lesson.id}", %{
               "lock_version" => v,
               "body" => "Second"
             })
             |> json_response(409)

    assert %{"error" => "invalid", "errors" => %{"lock_version" => _}} =
             me
             |> patch("/api/projects/#{p.id}/lessons/#{lesson.id}", %{"body" => "no version"})
             |> json_response(422)

    assert %{"error" => "conflict", "current" => %{"title" => "Le Jardin au clair de lune"}} =
             me
             |> patch("/api/projects/#{p.id}", %{"title" => "X", "lock_version" => 999})
             |> json_response(409)
  end

  test "modules and lessons: create, keyboard reordering, partial content, limits", %{
    me: me,
    project: p
  } do
    %{"module" => %{"id" => second}} =
      me
      |> post("/api/projects/#{p.id}/modules", %{"title" => "Night Bloom"})
      |> json_response(201)

    [first] = for m <- Repo.preload(p, :modules).modules, m.id != second, do: m.id

    assert %{
             "modules" => [
               %{"id" => ^second, "position" => 1},
               %{"id" => ^first, "position" => 2}
             ]
           } =
             me
             |> put("/api/projects/#{p.id}/modules/order", %{"module_ids" => [second, first]})
             |> json_response(200)

    assert %{"error" => "invalid"} =
             me
             |> put("/api/projects/#{p.id}/modules/order", %{"module_ids" => [second]})
             |> json_response(422)

    %{"lesson" => %{"id" => quiz, "kind" => "exercise", "xp_reward" => 20, "content" => content}} =
      me
      |> post("/api/projects/#{p.id}/modules/#{second}/lessons", %{
        "title" => "Petal quiz",
        "kind" => "exercise"
      })
      |> json_response(201)

    assert content == %{
             "question" => "",
             "choices" => ["", ""],
             "answer" => nil,
             "explanation" => ""
           }

    assert %{"lesson" => %{"content" => %{"question" => "Q?", "choices" => ["", ""]}}} =
             me
             |> patch("/api/projects/#{p.id}/lessons/#{quiz}", %{
               "lock_version" => 1,
               "content" => %{"question" => "Q?"}
             })
             |> json_response(200)

    assert %{"errors" => %{"content" => _}} =
             me
             |> patch("/api/projects/#{p.id}/lessons/#{quiz}", %{
               "lock_version" => 2,
               "content" => %{"answer" => "first"}
             })
             |> json_response(422)

    assert %{"errors" => %{"kind" => _}} =
             me
             |> post("/api/projects/#{p.id}/modules/#{second}/lessons", %{
               "title" => "Essay",
               "kind" => "essay"
             })
             |> json_response(422)

    assert me |> delete("/api/projects/#{p.id}/modules/#{second}") |> response(204)
    assert [%{position: 1}] = Repo.preload(p, :modules, force: true).modules
  end

  test "versions are immutable; restoring creates a new version", %{me: me, project: p} do
    assert %{"version" => %{"number" => 1, "source" => "manual", "note" => "First draft"}} =
             me
             |> post("/api/projects/#{p.id}/versions", %{"note" => "First draft"})
             |> json_response(201)

    me |> patch("/api/projects/#{p.id}", %{"title" => "Renamed garden", "lock_version" => 1})
    [module] = Repo.preload(p, :modules).modules
    me |> delete("/api/projects/#{p.id}/modules/#{module.id}")

    [%{"id" => v1}] =
      me |> get("/api/projects/#{p.id}/versions") |> json_response(200) |> Map.fetch!("versions")

    assert %{
             "version" => %{
               "number" => 2,
               "source" => "restore",
               "note" => "Restored from version 1"
             },
             "project" => %{
               "title" => "Le Jardin au clair de lune",
               "modules" => [%{"lessons" => [_, _, _]}]
             }
           } =
             me |> post("/api/projects/#{p.id}/versions/#{v1}/restore") |> json_response(201)

    assert [%{"number" => 2}, %{"number" => 1}] =
             me
             |> get("/api/projects/#{p.id}/versions")
             |> json_response(200)
             |> Map.fetch!("versions")

    assert_raise Postgrex.Error, ~r/versions are immutable/, fn ->
      Repo.update_all(from(v in Version, where: v.project_id == ^p.id), set: [note: "tampered"])
    end
  end

  test "images: signature check, 2 MB limit, alt text required, served to members only", %{
    conn: conn,
    me: me,
    project: p
  } do
    path = "/api/projects/#{p.id}/images"
    bytes = png()

    assert %{
             "image" => %{
               "id" => id,
               "content_type" => "image/png",
               "alt" => "A silver leaf",
               "source" => "upload"
             }
           } =
             me
             |> post(path, %{"data" => Base.encode64(bytes), "alt" => " A silver leaf "})
             |> json_response(201)

    served = me |> get("#{path}/#{id}")
    assert served.status == 200
    assert served.resp_body == bytes
    assert get_resp_header(served, "content-type") == ["image/png"]
    assert get_resp_header(served, "x-content-type-options") == ["nosniff"]

    # the declared name/type is ignored: only the signature counts
    gif = "GIF89a" <> :crypto.strong_rand_bytes(32)

    assert %{"errors" => %{"data" => [_]}} =
             me
             |> post(path, %{"data" => Base.encode64(gif), "alt" => "x", "filename" => "x.png"})
             |> json_response(422)

    assert %{"errors" => %{"alt" => ["can't be blank"]}} =
             me
             |> post(path, %{"data" => Base.encode64(bytes), "alt" => "  "})
             |> json_response(422)

    big = <<0xFF, 0xD8, 0xFF>> <> :binary.copy(<<0>>, 2 * 1024 * 1024)

    assert %{"errors" => %{"data" => ["must be at most 2 MB"]}} =
             me
             |> post(path, %{"data" => Base.encode64(big), "alt" => "big"})
             |> json_response(422)

    assert %{"image" => %{"alt" => "A brighter leaf"}} =
             me |> patch("#{path}/#{id}", %{"alt" => "A brighter leaf"}) |> json_response(200)

    assert %{"error" => "not_found"} =
             conn |> as_user(uuid()) |> get("#{path}/#{id}") |> json_response(404)

    assert me |> delete("#{path}/#{id}") |> response(204)
    assert %{"error" => "not_found"} = me |> get("#{path}/#{id}") |> json_response(404)
  end
end
