defmodule MysticWeb.LearnFormatsLiveTest do
  @moduledoc "Rendering and events of the video, simulation and mini-game lessons (learning is stubbed)."
  use MysticWeb.ConnCase, async: true

  @slug "l-atlas-celeste"

  defp lesson(id, kind, content, xp \\ 25),
    do: %{
      "lesson" => %{
        "id" => id,
        "title" => "Lesson #{id}",
        "kind" => kind,
        "body" => "The keeper opens the dome.",
        "content" => content,
        "xp_reward" => xp
      },
      "adventure" => %{"slug" => @slug, "title" => "L'Atlas céleste"},
      "progress" => %{"status" => "in_progress", "attempts" => 0, "notes" => "", "draft" => nil},
      "prev_id" => nil,
      "next_id" => nil
    }

  defp start(conn, routes, lesson_id, headers \\ []) do
    base =
      Map.merge(member_routes(user_fixture()), %{
        {"GET", "/api/adventures/#{@slug}"} => adventure_detail(%{"slug" => @slug})
      })

    stub_api(Map.merge(base, routes))
    conn = Enum.reduce(headers, log_in(conn), fn {k, v}, c -> put_req_header(c, k, v) end)
    {:ok, view, _html} = live(conn, ~p"/learn/#{@slug}/#{lesson_id}")
    view
  end

  @video %{
    "video" => %{
      "src" => "/media/lessons/reading-the-night-sky.webm",
      "type" => "video/webm",
      "poster" => "/media/lessons/reading-the-night-sky.jpg"
    },
    "captions" => [
      %{"lang" => "en", "label" => "English", "src" => "/media/lessons/r.en.vtt"},
      %{"lang" => "fr", "label" => "Français", "src" => "/media/lessons/r.fr.vtt"}
    ],
    "transcript" => "Tonight we read the sky.\n\nFind the pointers.",
    "duration_s" => 34
  }

  describe "video" do
    test "player with caption tracks (interface language by default), transcript, completion rule",
         %{conn: conn} do
      view =
        start(
          conn,
          %{
            {"GET", "/api/lessons/v1"} => lesson("v1", "video", @video, 15),
            {"POST", "/api/lessons/v1/complete"} => %{"xp" => "awarded"}
          },
          "v1"
        )

      assert has_element?(view, "#lesson-video[controls] source[type='video/webm']")
      assert has_element?(view, "#lesson-video track[kind='captions'][srclang='en'][default]")
      refute has_element?(view, "#lesson-video track[srclang='fr'][default]")
      assert has_element?(view, "#video-player-v1[phx-hook][phx-update='ignore']")
      assert has_element?(view, "#transcript[hidden]")
      assert has_element?(view, "#complete-lesson[disabled]")

      # the hook reports the share played: 85% unlocks the completion
      render_hook(view, "video_progress", %{"percent" => 85})
      assert has_element?(view, "#video-watched", "Watched: 85%")
      refute has_element?(view, "#complete-lesson[disabled]")

      view |> element("#complete-lesson") |> render_click()

      assert_received {:api,
                       %{
                         path: "/api/lessons/v1/complete",
                         body: %{"watched_percent" => 85, "transcript_opened" => false}
                       }}

      assert has_element?(view, "#xp-awarded", "+15 XP")
    end

    test "opening the transcript is enough; French interface → French captions first", %{
      conn: conn
    } do
      view =
        start(
          conn,
          %{
            {"GET", "/api/lessons/v1"} => lesson("v1", "video", @video, 15),
            {"POST", "/api/lessons/v1/complete"} => %{"xp" => "awarded"}
          },
          "v1",
          [{"accept-language", "fr-FR,fr;q=0.9"}]
        )

      assert has_element?(view, "#lesson-video track[srclang='fr'][default]")
      view |> element("#toggle-transcript") |> render_click()
      refute has_element?(view, "#transcript[hidden]")
      assert has_element?(view, "#toggle-transcript[aria-expanded='true']")
      assert has_element?(view, "#transcript", "Find the pointers.")
      view |> element("#complete-lesson") |> render_click()

      assert_received {:api,
                       %{path: "/api/lessons/v1/complete", body: %{"transcript_opened" => true}}}
    end
  end

  @orbit %{
    "model" => "orbit",
    "goal_text" => "Keep the planet on a round orbit.",
    "steps" => 1000,
    "params" => %{
      "velocity" => %{
        "min" => 4.0,
        "max" => 9.0,
        "step" => 0.1,
        "default" => 5.0,
        "label" => "Launch speed",
        "unit" => "AU/yr"
      }
    }
  }

  @run %{
    "model" => "orbit",
    "engine" => "native",
    "columns" => [
      %{"key" => "t", "label" => "Time", "unit" => "yr"},
      %{"key" => "x", "label" => "x", "unit" => "AU"},
      %{"key" => "y", "label" => "y", "unit" => "AU"},
      %{"key" => "r", "label" => "Distance", "unit" => "AU"}
    ],
    "frames" => [[0.0, 1.0, 0.0, 1.0], [0.5, -1.0, 0.01, 1.0], [1.0, 1.0, -0.002, 1.0]],
    "plot" => %{"type" => "path", "x" => "x", "y" => "y"},
    "metrics" => %{
      "eccentricity" => 0.004394,
      "r_min" => 1.0,
      "r_max" => 1.0088,
      "revolutions" => 1,
      "period" => 1.008,
      "bound" => true,
      "collided" => false,
      "escaped" => false
    },
    "description" => "In 2.00 years the planet completed 1 full orbit."
  }

  describe "simulation" do
    test "labelled bounded controls; run → plot, table and description; check → result", %{
      conn: conn
    } do
      view =
        start(
          conn,
          %{
            {"GET", "/api/lessons/s1"} => lesson("s1", "simulation", @orbit, 30),
            {"POST", "/api/lessons/s1/simulate"} => @run,
            {"POST", "/api/lessons/s1/submit"} => %{
              "correct" => true,
              "feedback" => "A stable, nearly circular orbit.",
              "xp" => "awarded",
              "trace" => nil
            }
          },
          "s1"
        )

      assert has_element?(view, "#sim-goal", "Keep the planet on a round orbit.")
      assert has_element?(view, "label[for='params_velocity']", "Launch speed (AU/yr)")

      assert has_element?(
               view,
               "#params_velocity[type='number'][min='4.0'][max='9.0'][step='0.1'][value='5.0']"
             )

      assert has_element?(view, "#params_velocity-hint", "From 4.0 to 9.0, in steps of 0.1.")

      view |> form("#sim-form", %{params: %{velocity: "6.3"}}) |> render_submit(%{do: "run"})

      assert_received {:api,
                       %{
                         path: "/api/lessons/s1/simulate",
                         body: %{"params" => %{"velocity" => 6.3}}
                       }}

      assert has_element?(
               view,
               "#sim-output[aria-live='polite'] #sim-description",
               "1 full orbit"
             )

      assert has_element?(view, "svg#sim-plot[aria-hidden='true'] polyline")
      assert has_element?(view, "#sim-table th[scope='col']", "Distance (AU)")
      assert has_element?(view, "#sim-table tbody tr", "0.5")
      assert has_element?(view, "#sim-metrics", "0.0044")

      view |> form("#sim-form", %{params: %{velocity: "6.3"}}) |> render_submit(%{do: "check"})

      assert_received {:api,
                       %{
                         path: "/api/lessons/s1/submit",
                         body: %{"answer" => ~s({"velocity":6.3})}
                       }}

      assert has_element?(view, "#xp-awarded", "+30 XP")
    end

    test "out-of-bounds values: the server's 422 is shown next to the field", %{conn: conn} do
      view =
        start(
          conn,
          %{
            {"GET", "/api/lessons/s1"} => lesson("s1", "simulation", @orbit, 30),
            {"POST", "/api/lessons/s1/simulate"} =>
              {422,
               %{
                 "error" => "invalid",
                 "errors" => %{"params.velocity" => ["must be between 4.0 and 9.0"]}
               }}
          },
          "s1"
        )

      view |> form("#sim-form", %{params: %{velocity: "50"}}) |> render_submit(%{do: "run"})

      assert_received {:api, %{body: %{"params" => %{"velocity" => 50}}}}
      assert has_element?(view, "#sim-error[role='alert']")
      assert has_element?(view, "#params_velocity-error", "must be between 4.0 and 9.0")
      assert has_element?(view, "#params_velocity[aria-invalid='true'][value='50']")
      refute has_element?(view, "#sim-table")
    end

    test "in French, the reaction run and its check are written in the member's language", %{
      conn: conn
    } do
      species = [
        %{"key" => "h2", "formula" => "H2", "side" => "reactant", "initial" => 10},
        %{"key" => "o2", "formula" => "O2", "side" => "reactant", "initial" => 5},
        %{"key" => "h2o", "formula" => "H2O", "side" => "product", "initial" => 0}
      ]

      content = %{
        "model" => "reaction",
        "goal_text" => "Équilibrez H2 + O2 → H2O.",
        "steps" => 6,
        "yield_pct" => 90,
        "species" => species,
        "params" =>
          Map.new(species, fn s ->
            {s["key"],
             %{
               "min" => 1,
               "max" => 8,
               "step" => 1,
               "default" => 1,
               "label" => "Coefficient de #{s["formula"]}",
               "unit" => ""
             }}
          end)
      }

      run = %{
        "model" => "reaction",
        "engine" => "native",
        "columns" => [
          %{"key" => "pass", "label" => "Pass", "unit" => ""},
          %{"key" => "h2", "label" => "H2", "unit" => "mol"},
          %{"key" => "o2", "label" => "O2", "unit" => "mol"},
          %{"key" => "h2o", "label" => "H2O", "unit" => "mol"},
          %{"key" => "atoms_H", "label" => "H atoms", "unit" => "mol"},
          %{"key" => "atoms_O", "label" => "O atoms", "unit" => "mol"}
        ],
        "frames" => [[0, 10.0, 5.0, 0.0, 20.0, 10.0], [1, 1.0, 0.5, 9.0, 20.0, 10.0]],
        "plot" => %{"type" => "lines", "x" => "pass", "y" => ["h2", "o2", "h2o"]},
        "metrics" => %{
          "atoms_left" => %{"H" => 4, "O" => 2},
          "atoms_right" => %{"H" => 4, "O" => 2},
          "balanced" => true,
          "lowest_terms" => true,
          "theoretical" => 10.0,
          "formed" => 10.0,
          "yield" => 1.0,
          "limiting" => "H2"
        },
        "description" => "2 H2 + O2 → 2 H2O. Every atom is conserved."
      }

      view =
        start(
          conn,
          %{
            {"GET", "/api/lessons/s2"} => lesson("s2", "simulation", content, 30),
            {"POST", "/api/lessons/s2/simulate"} => run,
            {"POST", "/api/lessons/s2/submit"} => %{
              "correct" => true,
              "feedback" => "Every atom is conserved: the equation is balanced.",
              "feedback_code" => "reaction_balanced",
              "feedback_params" => %{},
              "xp" => "awarded",
              "trace" => nil
            }
          },
          "s2",
          [{"accept-language", "fr-FR,fr;q=0.9"}]
        )

      coefficients = %{params: %{h2: "2", o2: "1", h2o: "2"}}
      view |> form("#sim-form", coefficients) |> render_submit(%{do: "run"})

      assert has_element?(view, "#sim-description", "2 H2 + O2 → 2 H2O. Atomes à gauche")
      assert has_element?(view, "#sim-description", "Tous les atomes sont conservés.")
      assert has_element?(view, "#sim-description", "10,00 mol de H2O")
      refute has_element?(view, "#sim-description", "Every atom")
      assert has_element?(view, "#sim-table th[scope='col']", "Passage")
      assert has_element?(view, "#sim-table th[scope='col']", "Atomes H (mol)")
      assert has_element?(view, "#sim-table tbody tr", "0,5")
      assert has_element?(view, "#sim-engine", "moteur natif")

      view |> form("#sim-form", coefficients) |> render_submit(%{do: "check"})

      assert has_element?(view, "#result", "l'équation est équilibrée")
      refute has_element?(view, "#result", "Every atom")
    end
  end

  @sequence %{
    "game" => "sequence",
    "prompt" => "Put the steps in a safe order.",
    "items" => [
      %{"id" => "c", "label" => "Light the burner"},
      %{"id" => "a", "label" => "Close the outlet"},
      %{"id" => "b", "label" => "Open the fuel"}
    ]
  }

  @constellation %{
    "game" => "constellation",
    "prompt" => "Trace the figure.",
    "stars" => [
      %{"id" => "s1", "name" => "Alpha", "x" => 10, "y" => 10},
      %{"id" => "s2", "name" => "Beta", "x" => 50, "y" => 50},
      %{"id" => "s3", "name" => "Gamma", "x" => 90, "y" => 90}
    ]
  }

  describe "mini-games" do
    test "sequence: keyboard moves, announcement, focus kept; the moves are sent for grading", %{
      conn: conn
    } do
      view =
        start(
          conn,
          %{
            {"GET", "/api/lessons/g1"} => lesson("g1", "minigame", @sequence),
            {"POST", "/api/lessons/g1/submit"} => fn _conn, %{"answer" => answer} ->
              if answer =~ "down",
                do: %{
                  "correct" => true,
                  "score" => 100,
                  "feedback" => "Everything is in the right order.",
                  "xp" => "awarded",
                  "trace" => nil
                },
                else: %{
                  "correct" => false,
                  "score" => 33,
                  "feedback" => "1 of 3 items are in the right place.",
                  "xp" => "none",
                  "trace" => nil
                }
            end
          },
          "g1"
        )

      assert has_element?(view, "#game-prompt", "Put the steps in a safe order.")
      assert has_element?(view, "#sequence-list li:first-child", "Light the burner")
      assert has_element?(view, "#item-c-up[disabled]")

      view |> element("#check-game") |> render_click()
      assert has_element?(view, "#game-score", "Score: 33/100")
      assert has_element?(view, "#result", "1 of 3 items")

      view |> element("#item-c-down") |> render_click()
      assert has_element?(view, "#sequence-list li:nth-child(2)", "Light the burner")
      assert has_element?(view, "#game-announce[aria-live='polite']", "moved to position 2 of 3")
      assert_push_event(view, "game:focus", %{id: "item-c-down"})
      assert has_element?(view, "#game-moves", "1 move")

      view |> element("#item-c-down") |> render_click()
      # at the bottom the "down" button is disabled: the focus goes to "up"
      assert_push_event(view, "game:focus", %{id: "item-c-up"})
      view |> element("#check-game") |> render_click()

      assert_received {:api,
                       %{
                         path: "/api/lessons/g1/submit",
                         body: %{
                           "answer" =>
                             ~s({"moves":[{"dir":"down","id":"c"},{"dir":"down","id":"c"}]})
                         }
                       }}

      assert has_element?(view, "#game-score", "Score: 100/100")
      assert has_element?(view, "#xp-awarded")

      view |> element("#reset-game") |> render_click()
      assert has_element?(view, "#sequence-list li:first-child", "Light the burner")
    end

    test "constellation: stars selected in order with buttons, path as text, undo", %{conn: conn} do
      view =
        start(
          conn,
          %{
            {"GET", "/api/lessons/g2"} => lesson("g2", "minigame", @constellation),
            {"POST", "/api/lessons/g2/submit"} => %{
              "correct" => true,
              "score" => 100,
              "feedback" => "The constellation shines.",
              "xp" => "awarded",
              "trace" => nil
            }
          },
          "g2"
        )

      assert has_element?(view, "svg#star-map[aria-hidden='true']")
      assert has_element?(view, "#star-s1", "top left of the map")
      assert has_element?(view, "#star-path", "No star selected yet.")

      for id <- ~w(s1 s2 s3 s2), do: view |> element("#star-#{id}") |> render_click()
      assert has_element?(view, "#star-path", "Alpha → Beta → Gamma → Beta")
      assert has_element?(view, "#star-s2 .star-order", "in your path: 2, 4")
      assert has_element?(view, "#game-announce", "Beta added: star 4 of your path.")

      view |> element("#undo-star") |> render_click()
      assert has_element?(view, "#star-path", "Alpha → Beta → Gamma")
      view |> element("#star-s2") |> render_click()
      view |> element("#check-game") |> render_click()

      assert_received {:api,
                       %{
                         path: "/api/lessons/g2/submit",
                         body: %{"answer" => ~s({"moves":["s1","s2","s3","s2"]})}
                       }}

      assert has_element?(view, "#result", "The constellation shines.")
    end

    test "a premium mini-game for a free member shows the upgrade notice", %{conn: conn} do
      view =
        start(
          conn,
          %{{"GET", "/api/lessons/g3"} => {402, %{"error" => "premium_required"}}},
          "g3"
        )

      assert has_element?(view, "#lesson-premium")
      assert has_element?(view, "#lesson-upgrade")
    end
  end
end
