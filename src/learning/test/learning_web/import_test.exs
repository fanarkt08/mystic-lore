defmodule MlLearningWeb.ImportTest do
  use MlLearningWeb.ConnCase, async: true

  defp studio(conn),
    do: put_req_header(conn, "authorization", "Bearer " <> MlShared.InternalToken.sign("studio"))

  defp payload(version, overrides \\ %{}) do
    %{
      "external_id" => overrides[:external_id] || "11111111-2222-4333-8444-555555555555",
      "version" => version,
      "adventure" =>
        Map.merge(
          %{
            "title" => "Le Jardin au clair de lune",
            "summary" => "Grow a moonlit garden with loops.",
            "description" => "A studio-made adventure.",
            "category" => "coding",
            "difficulty" => "beginner",
            "duration_minutes" => 20,
            "objectives" => ["Use a loop to water every plant"],
            "cover" => "forest",
            "author_id" => "00000000-0000-4000-8000-000000000001",
            "chapters" => [
              %{
                "title" => "Moonrise",
                "lessons" => [
                  %{"title" => "A silver path", "kind" => "story", "body" => "The moon rises."},
                  %{
                    "title" => "Counting petals",
                    "kind" => "exercise",
                    "content" => %{
                      "question" => "What does range(4) give?",
                      "choices" => ["1, 2, 3, 4", "0, 1, 2, 3"]
                    },
                    "solution" => 1,
                    "explanation" => "range(4) starts at 0."
                  },
                  %{
                    "title" => "Four saplings",
                    "kind" => "coding",
                    "content" => %{"plants" => 4, "hints" => ["range(4)"]}
                  }
                ]
              }
            ]
          },
          overrides[:adventure] || %{}
        )
    }
  end

  defp import!(body),
    do: build_conn() |> studio() |> post("/api/internal/adventures/import", body)

  test "imports a playable adventure: quiz solution hidden, coding graded with its plant count" do
    assert %{"slug" => "le-jardin-au-clair-de-lune", "version" => 1} =
             import!(payload(1)) |> json_response(200)

    user = Ecto.UUID.generate()

    detail =
      build_conn()
      |> as_user(user)
      |> get("/api/adventures/le-jardin-au-clair-de-lune")
      |> json_response(200)

    assert detail["access"] == "open"
    [%{"lessons" => [_story, quiz, code]}] = detail["chapters"]

    quiz_body =
      build_conn() |> as_user(user) |> get("/api/lessons/#{quiz["id"]}") |> json_response(200)

    refute inspect(quiz_body) =~ "range(4) starts at 0"

    assert %{"correct" => true} =
             build_conn()
             |> as_user(user)
             |> post("/api/lessons/#{quiz["id"]}/submit", %{"answer" => "1"})
             |> json_response(200)

    three = "for p in range(3):\n    water(p)\n"
    four = "for p in range(4):\n    water(p)\n"

    assert %{"correct" => false} =
             build_conn()
             |> as_user(user)
             |> post("/api/lessons/#{code["id"]}/submit", %{"answer" => three})
             |> json_response(200)

    assert %{"correct" => true, "trace" => [0, 1, 2, 3]} =
             build_conn()
             |> as_user(user)
             |> post("/api/lessons/#{code["id"]}/submit", %{"answer" => four})
             |> json_response(200)
  end

  test "same version is idempotent, older version is refused, newer version keeps lesson ids and progress" do
    %{"slug" => slug} = import!(payload(2)) |> json_response(200)
    assert %{"slug" => ^slug, "version" => 2} = import!(payload(2)) |> json_response(200)
    assert %{"error" => "stale_version"} = import!(payload(1)) |> json_response(409)

    user = Ecto.UUID.generate()

    [%{"lessons" => [story | _]}] =
      build_conn()
      |> as_user(user)
      |> get("/api/adventures/#{slug}")
      |> json_response(200)
      |> Map.fetch!("chapters")

    assert %{"xp" => "awarded"} =
             build_conn()
             |> as_user(user)
             |> post("/api/lessons/#{story["id"]}/complete")
             |> json_response(200)

    # v3 : titre de la leçon 1 modifié, leçons 2 et 3 retirées (sans progression → supprimées)
    v3 =
      payload(3, %{
        adventure: %{
          "chapters" => [
            %{
              "title" => "Moonrise",
              "lessons" => [
                %{"title" => "A golden path", "kind" => "story", "body" => "Changed."}
              ]
            }
          ]
        }
      })

    assert %{"slug" => ^slug, "version" => 3} = import!(v3) |> json_response(200)
    detail = build_conn() |> as_user(user) |> get("/api/adventures/#{slug}") |> json_response(200)

    assert [%{"lessons" => [%{"id" => id, "title" => "A golden path", "completed" => true}]}] =
             detail["chapters"]

    assert id == story["id"]
  end

  test "a removed lesson that has learner progress is kept at the end" do
    ext = "11111111-2222-4333-8444-666666666666"
    %{"slug" => slug} = import!(payload(1, %{external_id: ext})) |> json_response(200)
    user = Ecto.UUID.generate()

    [%{"lessons" => [_s, _q, code]}] =
      build_conn()
      |> as_user(user)
      |> get("/api/adventures/#{slug}")
      |> json_response(200)
      |> Map.fetch!("chapters")

    build_conn()
    |> as_user(user)
    |> put("/api/lessons/#{code["id"]}/notes", %{"notes" => "mine"})
    |> response(204)

    v2 =
      payload(2, %{
        external_id: ext,
        adventure: %{
          "chapters" => [
            %{"title" => "Moonrise", "lessons" => [%{"title" => "Only story", "kind" => "story"}]}
          ]
        }
      })

    import!(v2) |> json_response(200)

    [%{"lessons" => lessons}] =
      build_conn()
      |> as_user(user)
      |> get("/api/adventures/#{slug}")
      |> json_response(200)
      |> Map.fetch!("chapters")

    assert Enum.map(lessons, & &1["title"]) == ["Only story", "Four saplings"]
  end

  test "validation errors, unsupported formats, and only studio may import" do
    bad =
      payload(1, %{
        adventure: %{
          "category" => "magic",
          "chapters" => [%{"title" => "x", "lessons" => [%{"kind" => "video", "title" => "v"}]}]
        }
      })

    assert %{"error" => "invalid", "errors" => errors} = import!(bad) |> json_response(422)
    assert Map.has_key?(errors, "category") and Map.has_key?(errors, "chapters")

    bad_quiz =
      payload(1, %{
        adventure: %{
          "chapters" => [
            %{
              "title" => "x",
              "lessons" => [
                %{
                  "kind" => "exercise",
                  "title" => "q",
                  "content" => %{"question" => "?", "choices" => ["a", "b"]},
                  "solution" => 5
                }
              ]
            }
          ]
        }
      })

    assert import!(bad_quiz) |> json_response(422)

    bad_code =
      payload(1, %{
        adventure: %{
          "chapters" => [
            %{
              "title" => "x",
              "lessons" => [%{"kind" => "coding", "title" => "c", "content" => %{"plants" => 11}}]
            }
          ]
        }
      })

    assert import!(bad_code) |> json_response(422)

    other =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign("web"))
      |> post("/api/internal/adventures/import", payload(1))

    assert json_response(other, 403) == %{"error" => "forbidden"}

    assert build_conn()
           |> post("/api/internal/adventures/import", payload(1))
           |> json_response(401)
  end

  describe "video, simulation and mini-game lessons" do
    @video_id "aaaaaaaa-1111-4222-8333-444444444444"
    @captions_id "bbbbbbbb-1111-4222-8333-444444444444"

    defp formats_payload(lessons),
      do:
        payload(1, %{
          external_id: "99999999-2222-4333-8444-555555555555",
          adventure: %{
            "title" => "Formats of the Night",
            "chapters" => [%{"title" => "Sky", "lessons" => lessons}]
          }
        })

    defp video_lesson_payload(overrides \\ %{}),
      do:
        Map.merge(
          %{
            "title" => "Night film",
            "kind" => "video",
            "body" => "Watch the sky.",
            "content" => %{
              "video" => %{"media_id" => @video_id, "content_type" => "video/webm"},
              "captions" => [%{"media_id" => @captions_id, "lang" => "en", "label" => "English"}],
              "transcript" => "Stars turn around the pole.",
              "duration_s" => 31
            }
          },
          overrides
        )

    defp simulation_payload(solution \\ %{"max_eccentricity" => 0.05, "min_revolutions" => 1}),
      do: %{
        "title" => "Orbit lab",
        "kind" => "simulation",
        "content" => %{
          "model" => "orbit",
          "goal_text" => "Make it round.",
          "steps" => 1000,
          "params" => %{"velocity" => %{"min" => 4, "max" => 9, "step" => 0.1, "default" => 5}},
          "fixed" => %{"dt" => 0.002}
        },
        "solution" => solution
      }

    test "media paths are built from the studio media ids; criterion and order stay hidden" do
      body =
        formats_payload([
          video_lesson_payload(),
          simulation_payload(),
          %{
            "title" => "Sort it",
            "kind" => "minigame",
            "content" => %{
              "game" => "sequence",
              "prompt" => "Order them.",
              "items" => ~w(one two three)
            }
          }
        ])

      assert %{"slug" => slug} = import!(body) |> json_response(200)
      user = Ecto.UUID.generate()

      [%{"lessons" => [video, sim, game]}] =
        build_conn()
        |> as_user(user)
        |> get("/api/adventures/#{slug}")
        |> json_response(200)
        |> Map.fetch!("chapters")

      assert %{"kind" => "video", "xp_reward" => 15} = video
      assert %{"kind" => "simulation", "xp_reward" => 30} = sim
      assert %{"kind" => "minigame", "xp_reward" => 25} = game

      get = fn id ->
        build_conn() |> as_user(user) |> get("/api/lessons/#{id}") |> json_response(200)
      end

      assert %{
               "video" => %{
                 "src" => "/media/studio/" <> @video_id,
                 "type" => "video/webm",
                 "poster" => nil
               },
               "captions" => [%{"src" => "/media/studio/" <> @captions_id, "lang" => "en"}],
               "transcript" => "Stars turn around the pole.",
               "duration_s" => 31
             } = get.(video["id"])["lesson"]["content"]

      sim_body = get.(sim["id"])

      assert %{"model" => "orbit", "params" => %{"velocity" => %{"label" => "Launch speed"}}} =
               sim_body["lesson"]["content"]

      refute Jason.encode!(sim_body) =~ "eccentricity"
      refute Jason.encode!(get.(game["id"])) =~ ~s("order")

      assert %{"correct" => true} =
               build_conn()
               |> as_user(user)
               |> post("/api/lessons/#{sim["id"]}/submit", %{"answer" => ~s({"velocity": 6.3})})
               |> json_response(200)
    end

    test "invalid formats are refused with a precise message" do
      for {lesson, message} <- [
            {video_lesson_payload(%{
               "content" => %{
                 "video" => %{"media_id" => @video_id, "content_type" => "video/webm"},
                 "captions" => [],
                 "transcript" => "x",
                 "duration_s" => 3
               }
             }), "captions"},
            {video_lesson_payload(%{
               "content" => %{
                 "video" => %{"media_id" => @video_id, "content_type" => "video/webm"},
                 "captions" => [
                   %{"media_id" => @captions_id, "lang" => "en", "label" => "English"}
                 ],
                 "transcript" => " ",
                 "duration_s" => 3
               }
             }), "transcript"},
            {video_lesson_payload(%{
               "content" => %{
                 "video" => %{"media_id" => "../etc/passwd", "content_type" => "video/webm"}
               }
             }), "media"},
            {simulation_payload(%{}), "max_eccentricity"},
            {put_in(simulation_payload(), ["content", "params", "velocity", "max"], 50),
             "params.velocity"},
            {%{
               "title" => "g",
               "kind" => "minigame",
               "content" => %{"game" => "sequence", "prompt" => "p", "items" => ~w(a b)}
             }, "items"},
            {%{
               "title" => "g",
               "kind" => "minigame",
               "content" => %{"game" => "maze", "prompt" => "p"}
             }, "game"}
          ] do
        assert %{"errors" => %{"chapters" => [detail]}} =
                 import!(formats_payload([lesson])) |> json_response(422)

        assert detail =~ message, detail
      end
    end
  end
end
