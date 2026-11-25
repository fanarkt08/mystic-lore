defmodule MysticWeb.LearnLiveTest do
  use MysticWeb.ConnCase, async: true

  @slug "la-foret-des-murmures"

  defp lesson(id, kind, xp, attrs \\ %{}) do
    content =
      case kind do
        "story" ->
          %{}

        "exercise" ->
          %{
            "question" => "What does range(3) produce?",
            "choices" => ["1, 2, 3", "0, 1, 2", "0, 1, 2, 3"]
          }

        "coding" ->
          %{
            "starter" => "for plant in range(3):\n    water(plant)\n",
            "hints" => ["range(3) gives 0, 1, 2."],
            "plants" => 3,
            "language_note" => "A tiny, bounded Grove language."
          }
      end

    Map.merge(
      %{
        "lesson" => %{
          "id" => id,
          "title" => "Lesson #{id}",
          "kind" => kind,
          "body" => "Mist curls between the oaks.\n\nA loop repeats a spell.",
          "content" => content,
          "xp_reward" => xp
        },
        "adventure" => %{"slug" => @slug, "title" => "La Forêt des murmures"},
        "progress" => %{"status" => "in_progress", "attempts" => 0, "notes" => "", "draft" => nil},
        "prev_id" => nil,
        "next_id" => "l2"
      },
      attrs
    )
  end

  defp start(conn, routes, lesson_id) do
    user = user_fixture()

    base =
      Map.merge(member_routes(user), %{{"GET", "/api/adventures/#{@slug}"} => adventure_detail()})

    stub_api(Map.merge(base, routes))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/learn/#{@slug}/#{lesson_id}")
    view
  end

  test "story: mark complete awards the lesson XP once", %{conn: conn} do
    view =
      start(
        conn,
        %{
          {"GET", "/api/lessons/l1"} => lesson("l1", "story", 10),
          {"POST", "/api/lessons/l1/complete"} => %{"xp" => "awarded"}
        },
        "l1"
      )

    assert has_element?(
             view,
             "nav[aria-label='Chapters'] a[aria-current='page']",
             "Le bosquet se réveille"
           )

    view |> element("#complete-lesson") |> render_click()
    assert has_element?(view, "#xp-awarded", "+10 XP")
    assert has_element?(view, "#lesson-completed")

    stub_api(
      Map.merge(member_routes(user_fixture()), %{
        {"GET", "/api/adventures/#{@slug}"} => adventure_detail(),
        {"POST", "/api/lessons/l1/complete"} => %{"xp" => "duplicate"}
      })
    )

    view |> element("#complete-lesson") |> render_click()
    assert has_element?(view, "#xp-duplicate", "Already completed — XP granted once.")
  end

  test "quiz: sends the chosen index and shows the feedback", %{conn: conn} do
    view =
      start(
        conn,
        %{
          {"GET", "/api/lessons/l2"} => lesson("l2", "exercise", 20),
          {"POST", "/api/lessons/l2/submit"} => fn _conn, %{"answer" => answer} ->
            if answer == "1",
              do: %{
                "correct" => true,
                "feedback" => "range(3) yields 0, 1, 2.",
                "xp" => "awarded",
                "trace" => nil
              },
              else: %{
                "correct" => false,
                "feedback" => "Counting starts at 0.",
                "xp" => "none",
                "trace" => nil
              }
          end
        },
        "l2"
      )

    view |> form("#quiz-form", %{answer: "0"}) |> render_submit()
    assert has_element?(view, "#result", "Not quite")
    assert has_element?(view, "#result", "Counting starts at 0.")
    refute has_element?(view, "#xp-awarded")

    view |> form("#quiz-form", %{answer: "1"}) |> render_submit()
    assert has_element?(view, "#result", "Well done!")
    assert has_element?(view, "#xp-awarded", "+20 XP")

    assert_received {:api,
                     %{method: "POST", path: "/api/lessons/l2/submit", body: %{"answer" => "1"}}}
  end

  test "coding: draft autosave, run & check with the grove trace", %{conn: conn} do
    code = "for plant in range(3):\n    water(plant)"

    view =
      start(
        conn,
        %{
          {"GET", "/api/lessons/l3"} => lesson("l3", "coding", 40),
          {"PUT", "/api/lessons/l3/draft"} => {204, nil},
          {"POST", "/api/lessons/l3/submit"} => %{
            "correct" => true,
            "feedback" => "The grove drinks.",
            "xp" => "awarded",
            "trace" => [0, 1, 2]
          }
        },
        "l3"
      )

    assert has_element?(view, "#code", "for plant in range(3):")

    view |> form("#code-form", %{code: code}) |> render_change()

    assert_received {:api,
                     %{method: "PUT", path: "/api/lessons/l3/draft", body: %{"draft" => ^code}}}

    assert has_element?(view, "#draft-status", "Draft saved.")

    view |> form("#code-form", %{code: code}) |> render_submit()

    assert_received {:api,
                     %{method: "POST", path: "/api/lessons/l3/submit", body: %{"answer" => ^code}}}

    assert has_element?(view, "#grove-trace", "watered 0, 1, 2")
    assert has_element?(view, "#xp-awarded", "+40 XP")
  end

  test "a script error shows the feedback without trace", %{conn: conn} do
    view =
      start(
        conn,
        %{
          {"GET", "/api/lessons/l3"} => lesson("l3", "coding", 40),
          {"POST", "/api/lessons/l3/submit"} => %{
            "correct" => false,
            "feedback" => "Script error: Unknown instruction",
            "xp" => "none",
            "trace" => nil
          }
        },
        "l3"
      )

    view |> form("#code-form", %{code: "print(1)"}) |> render_submit()
    assert has_element?(view, "#result", "Script error")
    refute has_element?(view, "#grove-trace")
  end

  test "personal notes are saved", %{conn: conn} do
    view =
      start(
        conn,
        %{
          {"GET", "/api/lessons/l1"} => lesson("l1", "story", 10),
          {"PUT", "/api/lessons/l1/notes"} => {204, nil}
        },
        "l1"
      )

    view |> form("#notes-form", %{notes: "range stops before 3"}) |> render_submit()

    assert_received {:api,
                     %{
                       method: "PUT",
                       path: "/api/lessons/l1/notes",
                       body: %{"notes" => "range stops before 3"}
                     }}

    assert has_element?(view, "#notes-status", "Notes saved.")
  end

  test "next lesson is a live patch", %{conn: conn} do
    view =
      start(
        conn,
        %{
          {"GET", "/api/lessons/l1"} => lesson("l1", "story", 10),
          {"GET", "/api/lessons/l2"} =>
            lesson("l2", "exercise", 20, %{"prev_id" => "l1", "next_id" => nil})
        },
        "l1"
      )

    view |> element("#next-lesson") |> render_click()
    assert_patch(view, ~p"/learn/#{@slug}/l2")
    assert has_element?(view, "#quiz-form")
    assert has_element?(view, "#end-adventure")
  end

  test "premium lessons (402) point to the membership page", %{conn: conn} do
    view =
      start(conn, %{{"GET", "/api/lessons/l9"} => {402, %{"error" => "premium_required"}}}, "l9")

    assert has_element?(view, "#lesson-premium #lesson-upgrade[href='/membership']")
  end

  test "an unverifiable premium check (503) asks to retry, not to upgrade", %{conn: conn} do
    view =
      start(
        conn,
        %{{"GET", "/api/lessons/l9"} => {503, %{"error" => "entitlements_unavailable"}}},
        "l9"
      )

    assert has_element?(view, "#lesson-unavailable", "Premium access can't be verified right now")
    refute has_element?(view, "#lesson-upgrade")
  end
end
