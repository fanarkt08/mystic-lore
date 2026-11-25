defmodule MysticWeb.Studio.FormatsEditorTest do
  @moduledoc "Studio editors of the video, simulation and mini-game lessons, and the media proxies."
  use MysticWeb.ConnCase, async: true
  import MysticWeb.StudioFixtures

  @webm <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x84, "webm", 1, 2, 3, 4>>
  @vtt "WEBVTT\n\n00:00.500 --> 00:04.000\nTonight we read the sky.\n"

  defp project(lessons, media \\ []) do
    studio_project(%{
      "media" => media,
      "modules" => [
        %{
          "id" => "m1",
          "position" => 1,
          "title" => "Sky",
          "lock_version" => 1,
          "lessons" => lessons
        }
      ]
    })
  end

  defp open(conn, project, lesson_id, extra) do
    user = user_fixture(%{"id" => "owner-1"})
    stub_api(studio_routes(member_routes(user), project, extra))
    {:ok, view, _html} = conn |> log_in() |> live("/studio/p1?step=build&lesson=#{lesson_id}")
    view
  end

  describe "video lesson" do
    setup do
      video =
        lesson("l9", "video", "Lire le ciel de nuit", %{
          "video_id" => "v1",
          "captions" => [%{"media_id" => "c1", "lang" => "en", "label" => "English"}],
          "transcript" => "Tonight we read the sky.",
          "duration_s" => 34
        })

      media = [
        %{
          "id" => "v1",
          "kind" => "video",
          "content_type" => "video/webm",
          "byte_size" => 1_887_436
        },
        %{
          "id" => "c1",
          "kind" => "captions",
          "content_type" => "text/vtt",
          "byte_size" => 80,
          "lang" => "en",
          "label" => "English"
        }
      ]

      %{project: project([video], media), video: video}
    end

    test "preview through the member proxy, transcript autosave never sends the media", %{
      conn: conn,
      project: project,
      video: video
    } do
      view =
        open(conn, project, "l9", %{
          {"PATCH", "/api/projects/p1/lessons/l9"} => %{"lesson" => video}
        })

      assert has_element?(view, "#video-current", "video/webm, 1.8 MB")
      assert has_element?(view, "#video-preview[src='/studio/p1/media/v1']")
      assert has_element?(view, "#video-preview track[src='/studio/p1/media/c1'][srclang='en']")
      assert has_element?(view, "#captions-en", "English")
      assert has_element?(view, "#video-upload-form")
      assert has_element?(view, "#captions-form")

      view
      |> form("#lesson-form", lesson: %{transcript: "Find the pointers.", duration_s: "40"})
      |> render_change()

      assert_received {:api, %{method: "PATCH", path: "/api/projects/p1/lessons/l9", body: body}}

      assert %{"content" => %{"transcript" => "Find the pointers.", "duration_s" => 40}} = body
      refute Map.has_key?(body["content"], "video_id")
    end

    test "uploads: the video as raw bytes, captions as WebVTT text; removal", %{
      conn: conn,
      project: project
    } do
      view =
        open(conn, project, "l9", %{
          {"POST", "/api/projects/p1/lessons/l9/video"} =>
            {201, %{"media" => %{}, "lesson" => %{}}},
          {"POST", "/api/projects/p1/lessons/l9/captions"} =>
            {422, %{"error" => "invalid", "errors" => %{"vtt" => ["must start with WEBVTT"]}}},
          {"DELETE", "/api/projects/p1/lessons/l9/captions/en"} => {204, nil}
        })

      file =
        file_input(view, "#video-upload-form", :video, [
          %{name: "night-sky.webm", content: @webm, type: "video/webm"}
        ])

      render_upload(file, "night-sky.webm")
      view |> form("#video-upload-form") |> render_submit()

      assert_received {:api,
                       %{method: "POST", path: "/api/projects/p1/lessons/l9/video", body: @webm}}

      captions =
        file_input(view, "#captions-form", :captions, [
          %{name: "sky.fr.vtt", content: "not webvtt", type: "text/vtt"}
        ])

      render_upload(captions, "sky.fr.vtt")
      view |> form("#captions-form", %{lang: "fr", label: ""}) |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/projects/p1/lessons/l9/captions",
                         body: %{"lang" => "fr", "label" => "Français", "vtt" => "not webvtt"}
                       }}

      assert render(view) =~ "must start with WEBVTT"

      view |> element("#delete-captions-en") |> render_click()
      assert_received {:api, %{method: "DELETE", path: "/api/projects/p1/lessons/l9/captions/en"}}
    end
  end

  test "simulation: bounds of the model; switching the model shows its own fields", %{conn: conn} do
    orbit = %{
      "model" => "orbit",
      "goal_text" => "",
      "steps" => 1000,
      "velocity" => %{"min" => 4, "max" => 9, "step" => 0.1, "default" => 5},
      "star_mass" => %{"min" => 0.5, "max" => 2, "step" => 0.1, "default" => 1},
      "distance" => 1,
      "dt" => 0.002,
      "max_eccentricity" => 0.03,
      "min_revolutions" => 1
    }

    sim = lesson("l10", "simulation", "Orbit lab", orbit)

    # the studio merges the partial content (MlStudio.Projects.Lesson)
    view =
      open(conn, project([sim]), "l10", %{
        {"PATCH", "/api/projects/p1/lessons/l10"} => fn _conn, body ->
          %{"lesson" => Map.update!(sim, "content", &Map.merge(&1, body["content"]))}
        end
      })

    assert has_element?(view, "#lesson_velocity_max[value='9']")
    assert has_element?(view, "#lesson_max_eccentricity[value='0.03']")

    view
    |> form("#lesson-form", lesson: %{goal_text: "Make it round.", velocity_max: "8.5"})
    |> render_change()

    assert_received {:api, %{method: "PATCH", body: %{"content" => content}}}

    assert %{
             "model" => "orbit",
             "goal_text" => "Make it round.",
             "steps" => 1000,
             "velocity" => %{"min" => 4, "max" => 8.5, "step" => 0.1, "default" => 5}
           } = content

    view |> form("#lesson-form", lesson: %{model: "reaction"}) |> render_change()

    assert_received {:api,
                     %{
                       method: "PATCH",
                       body: %{"content" => %{"model" => "reaction", "steps" => 6}}
                     }}

    assert has_element?(view, "#lesson_species")
    refute has_element?(view, "#lesson_velocity_max")

    view
    |> form("#lesson-form", lesson: %{species: "H2, reactant, 10\nO2, reactant, 5\nH2O, product"})
    |> render_change()

    assert_received {:api, %{method: "PATCH", body: %{"content" => %{"species" => species}}}}

    assert species == [
             %{"formula" => "H2", "side" => "reactant", "initial" => 10},
             %{"formula" => "O2", "side" => "reactant", "initial" => 5},
             %{"formula" => "H2O", "side" => "product", "initial" => 0}
           ]
  end

  test "mini-game: items in the expected order; constellation stars and path", %{conn: conn} do
    game =
      lesson("l11", "minigame", "Sort it", %{
        "game" => "sequence",
        "prompt" => "",
        "items" => [],
        "stars" => [],
        "path" => []
      })

    view =
      open(conn, project([game]), "l11", %{
        {"PATCH", "/api/projects/p1/lessons/l11"} => fn _conn, body ->
          %{"lesson" => Map.update!(game, "content", &Map.merge(&1, body["content"]))}
        end
      })

    view
    |> form("#lesson-form",
      lesson: %{prompt: "Oldest first.", items: "A tablet\nA chronicle\n\nA blog"}
    )
    |> render_change()

    assert_received {:api,
                     %{
                       body: %{
                         "content" => %{
                           "game" => "sequence",
                           "items" => ["A tablet", "A chronicle", "A blog"]
                         }
                       }
                     }}

    view |> form("#lesson-form", lesson: %{game: "constellation"}) |> render_change()
    assert has_element?(view, "#lesson_stars")

    view
    |> form("#lesson-form",
      lesson: %{stars: "Alkaid, 8, 62\nMizar, 24, 50", path: "Alkaid\nMizar"}
    )
    |> render_change()

    assert_received {:api,
                     %{body: %{"content" => %{"stars" => stars, "path" => ["Alkaid", "Mizar"]}}}}

    assert stars == [
             %{"name" => "Alkaid", "x" => 8, "y" => 62},
             %{"name" => "Mizar", "x" => 24, "y" => 50}
           ]
  end

  test "review: the new checks are explained", %{conn: conn} do
    checks = %{
      "ready" => false,
      "attestations" => nil,
      "checks" => [
        %{
          "key" => "videos",
          "ok" => false,
          "issues" => [
            %{
              "code" => "video_captions",
              "module" => 1,
              "lesson" => 1,
              "title" => "Film",
              "field" => nil,
              "image" => nil
            }
          ]
        }
      ]
    }

    user = user_fixture(%{"id" => "owner-1"})

    stub_api(
      studio_routes(member_routes(user), studio_project(), %{
        {"GET", "/api/projects/p1/checks"} => checks,
        {"GET", "/api/projects/p1/versions"} => %{"versions" => []}
      })
    )

    {:ok, view, _} = conn |> log_in() |> live("/studio/p1?step=review")
    assert has_element?(view, "#check-videos", "Videos with captions and a transcript")
    assert has_element?(view, "#check-videos", "add at least one WebVTT caption track")
  end

  describe "media proxies" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "published media: signed-in members only, type from the signature", %{
      conn: conn,
      user: user
    } do
      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/media/v1"} => fn conn, _ -> Plug.Conn.send_resp(conn, 200, @webm) end,
          {"GET", "/api/media/c1"} => fn conn, _ -> Plug.Conn.send_resp(conn, 200, @vtt) end,
          {"GET", "/api/media/draft"} => {404, %{"error" => "not_found"}}
        })
      )

      video = conn |> log_in() |> get("/media/studio/v1")
      assert response(video, 200) == @webm
      assert get_resp_header(video, "content-type") == ["video/webm"]
      assert get_resp_header(video, "x-content-type-options") == ["nosniff"]

      captions = conn |> log_in() |> get("/media/studio/c1")
      assert get_resp_header(captions, "content-type") == ["text/vtt; charset=utf-8"]

      assert conn |> log_in() |> get("/media/studio/draft") |> response(404)
      assert build_conn() |> get("/media/studio/v1") |> response(404)
    end

    test "the author's preview goes through the project route", %{conn: conn, user: user} do
      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/projects/p1/media/v1"} => fn conn, _ ->
            Plug.Conn.send_resp(conn, 200, @webm)
          end
        })
      )

      assert conn |> log_in() |> get("/studio/p1/media/v1") |> response(200) == @webm
      assert_received {:api, %{path: "/api/projects/p1/media/v1"}}
    end

    test "the seeded lesson media are served with their types and byte ranges", %{conn: conn} do
      vtt = get(conn, "/media/lessons/reading-the-night-sky.en.vtt")
      assert get_resp_header(vtt, "content-type") == ["text/vtt; charset=utf-8"]
      assert response(vtt, 200) =~ "WEBVTT"

      part =
        conn
        |> put_req_header("range", "bytes=0-3")
        |> get("/media/lessons/reading-the-night-sky.webm")

      assert response(part, 206) == <<0x1A, 0x45, 0xDF, 0xA3>>
      assert get_resp_header(part, "content-type") == ["video/webm"]
      assert get(conn, "/media/lessons/reading-the-night-sky.jpg") |> response(200)
    end
  end
end
