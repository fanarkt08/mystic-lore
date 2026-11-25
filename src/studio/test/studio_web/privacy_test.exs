defmodule MlStudioWeb.PrivacyTest do
  use MlStudioWeb.ConnCase, async: true
  alias MlStudio.AI
  alias MlStudio.AI.{Generation, Setting}
  alias MlStudio.Images
  alias MlStudio.Projects.{Collaborator, Project}

  defp caller(service, user_id \\ nil) do
    put_req_header(
      build_conn(),
      "authorization",
      "Bearer " <> MlShared.InternalToken.sign(service, user_id)
    )
  end

  defp collaborator!(project, user_id, role \\ "editor"),
    do:
      Repo.insert!(%Collaborator{
        project_id: project.id,
        user_id: user_id,
        username: "user_" <> String.slice(user_id, 0, 8),
        role: role,
        invited_by: project.owner_id
      })

  defp generation!(project, user_id, attrs \\ %{}),
    do:
      Repo.insert!(
        struct(
          %Generation{
            project_id: project.id,
            user_id: user_id,
            kind: "outline",
            cost: 2,
            provider: "demo",
            brief: "Plan a moonlit garden",
            status: "pending"
          },
          attrs
        )
      )

  setup do
    [me, friend] = for _ <- 1..2, do: uuid()
    solo = project_fixture(me, %{"title" => "My solo draft"})
    shared = project_fixture(me, %{"title" => "Our shared course"})
    collaborator!(shared, friend)
    published = project_fixture(me, %{"title" => "My published course"})

    Repo.update_all(from(p in Project, where: p.id == ^published.id),
      set: [status: "published", published_slug: "my-published-course"]
    )

    theirs = project_fixture(friend, %{"title" => "Friend's private notes"})
    collaborator!(theirs, me, "viewer")
    {:ok, true} = AI.set_consent(me, %{"share_drafts_with_ai" => true})
    pending = generation!(solo, me)
    done = generation!(shared, me, %{status: "succeeded", credits: "consumed", result: %{}})
    {:ok, _image} = Images.upload(me, solo.id, %{"data" => Base.encode64(png()), "alt" => "Moon"})

    %{
      me: me,
      friend: friend,
      solo: solo,
      shared: shared,
      published: published,
      theirs: theirs,
      pending: pending,
      done: done
    }
  end

  test "only the accounts service may call them (403 otherwise)", %{me: me, solo: solo} do
    for conn <- [caller("web", me), caller("learning"), caller("billing")] do
      assert %{"error" => "forbidden"} =
               conn |> get("/api/internal/users/#{me}/export") |> json_response(403)

      assert conn |> recycle() |> delete("/api/internal/users/#{me}") |> json_response(403)
    end

    assert Repo.get(Project, solo.id)
  end

  test "export: own projects with content, collaborations, generations; not others' content", %{
    me: me,
    theirs: theirs
  } do
    assert %{"data" => data} =
             caller("accounts") |> get("/api/internal/users/#{me}/export") |> json_response(200)

    assert data["ai_settings"] == %{"share_drafts_with_ai" => true}

    assert Enum.map(data["projects"], & &1["title"]) |> Enum.sort() ==
             ["My published course", "My solo draft", "Our shared course"]

    solo = Enum.find(data["projects"], &(&1["title"] == "My solo draft"))
    assert [%{"lessons" => [_, _, _]}] = solo["modules"]
    assert [%{"alt" => "Moon"}] = solo["images"]
    assert is_list(solo["versions"])

    theirs_id = theirs.id
    assert [%{"project_id" => ^theirs_id, "role" => "viewer"}] = data["collaborations"]
    assert [_, _] = data["generations"]
    assert Enum.all?(data["generations"], &(&1["brief"] == "Plan a moonlit garden"))
    assert [%{"content_type" => "image/png"}] = data["images_uploaded"]
    refute Enum.any?(data["projects"], &(&1["title"] == "Friend's private notes"))
  end

  test "DELETE: credits released first, solo draft deleted, shared and published kept without owner",
       %{me: me, friend: friend, solo: solo, shared: shared, published: published, theirs: theirs} do
    stub_services(credit_routes())
    solo_dir = Path.dirname(Images.path(%Images.Image{project_id: solo.id, id: "x"}))
    assert File.exists?(solo_dir)

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)

    assert_received {:service, %{path: "/api/internal/credits/release", body: %{"ref" => ref}}}
    assert "studio:gen:" <> _ = ref

    refute Repo.get(Project, solo.id)
    refute File.exists?(solo_dir)
    assert %Project{owner_id: nil} = Repo.get!(Project, shared.id)
    assert %Project{owner_id: nil, status: "published"} = Repo.get!(Project, published.id)
    assert %Project{owner_id: ^friend} = Repo.get!(Project, theirs.id)

    assert Repo.all(from c in Collaborator, where: c.user_id == ^me) == []
    assert Repo.all(from g in Generation, where: g.user_id == ^me) == []
    refute Repo.get(Setting, me)

    # the collaborator keeps working on the shared project
    assert %{"project" => %{"role" => "editor", "owner_id" => nil}} =
             build_conn()
             |> as_user(friend)
             |> get("/api/projects/#{shared.id}")
             |> json_response(200)

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
  end

  test "billing unreachable: 503 and nothing deleted (accounts retries)", %{me: me, solo: solo} do
    stub_services(%{{"POST", "/api/internal/credits/release"} => :unavailable})

    assert %{"error" => "credits_unavailable"} =
             caller("accounts") |> delete("/api/internal/users/#{me}") |> json_response(503)

    assert Repo.get(Project, solo.id)
    assert [_, _] = Repo.all(from g in Generation, where: g.user_id == ^me)
  end
end
