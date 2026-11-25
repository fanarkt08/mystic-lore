defmodule MlLearningWeb.ApiTest do
  use MlLearningWeb.ConnCase, async: true

  @card_keys ~w(category cover difficulty duration_minutes id premium slug summary title)
  @detail_keys @card_keys ++
                 ~w(access chapters description enrolled objectives prerequisites progress resume_lesson_id)

  setup do
    adventure =
      adventure_fixture(%{title: "La Forêt des murmures"}, [
        [%{title: "Le bosquet se réveille"}, quiz()],
        [coding()]
      ])

    [story, exercise, code] = lessons_of(adventure)
    %{adventure: adventure, story: story, exercise: exercise, code: code, user: user_id()}
  end

  describe "tokens" do
    test "healthz needs no token", %{conn: conn} do
      assert json_response(get(conn, "/healthz"), 200) == %{"status" => "ok"}
    end

    test "every /api route requires a valid internal token", %{conn: conn} do
      assert json_response(get(conn, "/api/adventures"), 401) == %{"error" => "unauthorized"}

      tampered =
        put_req_header(
          conn,
          "authorization",
          "Bearer " <> MlShared.InternalToken.sign("web") <> "x"
        )

      assert json_response(get(tampered, "/api/adventures"), 401) == %{"error" => "unauthorized"}
      assert %{"entries" => [_]} = json_response(get(as_service(conn), "/api/adventures"), 200)
    end

    test "user routes require a user in the token", %{
      conn: conn,
      adventure: adventure,
      story: story
    } do
      for {method, path} <- [
            {:get, "/api/me/dashboard"},
            {:post, "/api/adventures/#{adventure.slug}/enroll"},
            {:get, "/api/lessons/#{story.id}"},
            {:post, "/api/lessons/#{story.id}/submit"},
            {:post, "/api/lessons/#{story.id}/complete"},
            {:put, "/api/lessons/#{story.id}/notes"},
            {:put, "/api/lessons/#{story.id}/draft"}
          ] do
        conn = dispatch(as_service(conn), @endpoint, method, path, %{})
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, "#{method} #{path}"
      end
    end

    test "a user id that is not a UUID is rejected", %{conn: conn} do
      assert json_response(get(as_user(conn, "lea"), "/api/me/dashboard"), 401) == %{
               "error" => "unauthorized"
             }
    end

    test "unknown routes answer in the contract's error format", %{conn: conn} do
      assert json_response(get(as_service(conn), "/api/nope"), 404) == %{"error" => "not_found"}
    end
  end

  describe "catalogue" do
    test "lists adventure cards with pagination", %{conn: conn, adventure: adventure} do
      body = json_response(get(as_service(conn), "/api/adventures", q: "murmures"), 200)
      assert %{"page" => 1, "total" => 1, "total_pages" => 1, "entries" => [card]} = body
      assert Enum.sort(Map.keys(card)) == @card_keys
      assert card["slug"] == adventure.slug
    end

    test "anonymous detail: chapters and lessons, login required, no user state", %{
      conn: conn,
      adventure: adventure
    } do
      body = json_response(get(as_service(conn), "/api/adventures/#{adventure.slug}"), 200)
      assert Enum.sort(Map.keys(body)) == Enum.sort(@detail_keys)

      assert %{
               "access" => "login_required",
               "enrolled" => false,
               "progress" => nil,
               "resume_lesson_id" => nil
             } = body

      assert [
               %{"position" => 1, "lessons" => [first, second]},
               %{"position" => 2, "lessons" => [third]}
             ] = body["chapters"]

      assert Enum.sort(Map.keys(first)) == ~w(completed id kind position title xp_reward)
      assert [first["kind"], second["kind"], third["kind"]] == ["story", "exercise", "coding"]

      assert %{"title" => "Le bosquet se réveille", "completed" => false, "xp_reward" => 10} =
               first
    end

    test "user detail: enrollment, progress, completed lessons and resume point",
         %{conn: conn} = ctx do
      assert json_response(
               post(as_user(conn, ctx.user), "/api/lessons/#{ctx.story.id}/complete"),
               200
             )

      body =
        json_response(get(as_user(conn, ctx.user), "/api/adventures/#{ctx.adventure.slug}"), 200)

      assert %{
               "access" => "open",
               "enrolled" => true,
               "progress" => %{"done" => 1, "total" => 3, "percent" => 33}
             } = body

      assert body["resume_lesson_id"] == ctx.exercise.id

      assert [%{"lessons" => [%{"completed" => true}, %{"completed" => false}]}, _] =
               body["chapters"]
    end

    test "enrollment is idempotent", %{conn: conn, adventure: adventure, user: user} do
      for _ <- 1..2 do
        assert json_response(
                 post(as_user(conn, user), "/api/adventures/#{adventure.slug}/enroll"),
                 200
               ) == %{"enrolled" => true}
      end

      assert %{"enrolled" => true, "resume_lesson_id" => resume} =
               json_response(get(as_user(conn, user), "/api/adventures/#{adventure.slug}"), 200)

      assert resume == hd(lessons_of(adventure)).id
    end

    test "a NUL byte in a filter is answered 400 bad_request (rejected by PostgreSQL)", %{
      conn: conn
    } do
      assert {400, _headers, body} =
               assert_error_sent(400, fn -> get(as_service(conn), "/api/adventures", q: <<0>>) end)

      assert Jason.decode!(body) == %{"error" => "bad_request"}
    end

    test "unknown adventures are 404", %{conn: conn, user: user} do
      assert json_response(get(as_service(conn), "/api/adventures/nope"), 404) == %{
               "error" => "not_found"
             }

      assert json_response(post(as_user(conn, user), "/api/adventures/nope/enroll"), 404) == %{
               "error" => "not_found"
             }
    end
  end

  describe "lessons" do
    test "an exercise exposes its question and choices, never the answer",
         %{conn: conn, exercise: exercise} = ctx do
      conn = get(as_user(conn, ctx.user), "/api/lessons/#{exercise.id}")
      body = json_response(conn, 200)

      assert body["lesson"]["content"] == %{
               "question" => "What does range(3) produce?",
               "choices" => ["1, 2, 3", "0, 1, 2", "3, 2, 1"]
             }

      assert Enum.sort(Map.keys(body["lesson"])) == ~w(body content id kind title xp_reward)
      refute conn.resp_body =~ "solution"
      refute conn.resp_body =~ "stops before 3"
      refute conn.resp_body =~ "Counting starts at zero"

      assert %{
               "adventure" => %{"slug" => _, "title" => "La Forêt des murmures"},
               "progress" => %{
                 "status" => "in_progress",
                 "attempts" => 0,
                 "notes" => nil,
                 "draft" => nil
               },
               "prev_id" => prev_id,
               "next_id" => next_id
             } = body

      assert {prev_id, next_id} == {ctx.story.id, ctx.code.id}
    end

    test "opening a lesson enrolls and becomes the resume point", %{conn: conn} = ctx do
      assert json_response(get(as_user(conn, ctx.user), "/api/lessons/#{ctx.code.id}"), 200)[
               "prev_id"
             ] == ctx.exercise.id

      assert %{"enrolled" => true, "resume_lesson_id" => resume} =
               json_response(
                 get(as_user(conn, ctx.user), "/api/adventures/#{ctx.adventure.slug}"),
                 200
               )

      assert resume == ctx.code.id
    end

    test "quiz submissions: a wrong answer gets a hint, the right one XP once",
         %{conn: conn} = ctx do
      submit = fn answer ->
        json_response(
          post(as_user(conn, ctx.user), "/api/lessons/#{ctx.exercise.id}/submit", answer: answer),
          200
        )
      end

      wrong = submit.("1, 2, 3")

      assert wrong == %{
               "correct" => false,
               "feedback" => "Counting starts at zero.",
               "xp" => "none",
               "trace" => nil
             }

      refute wrong["feedback"] =~ "0, 1, 2"

      assert %{
               "correct" => true,
               "xp" => "awarded",
               "feedback" => "range(3) starts at 0 and stops before 3."
             } = submit.("0, 1, 2")

      # Le choix peut aussi être désigné par son index.
      assert %{"correct" => true, "xp" => "duplicate"} = submit.("1")
      assert %{"correct" => false, "xp" => "none"} = submit.("7")

      assert %{"progress" => %{"status" => "completed", "attempts" => 4}} =
               json_response(get(as_user(conn, ctx.user), "/api/lessons/#{ctx.exercise.id}"), 200)
    end

    test "coding submissions are graded by GroveScript, never executed", %{conn: conn} = ctx do
      submit = fn answer ->
        json_response(
          post(as_user(conn, ctx.user), "/api/lessons/#{ctx.code.id}/submit", answer: answer),
          200
        )
      end

      assert %{
               "correct" => false,
               "trace" => nil,
               "xp" => "none",
               "feedback" => "Script error: " <> _
             } =
               submit.("File.write!(\"/tmp/pwned\", \"x\")")

      assert %{"correct" => false, "trace" => [0, 1, 2], "xp" => "none"} =
               submit.("water(0)\nwater(1)\nwater(2)")

      assert %{"correct" => true, "trace" => [0, 1, 2], "xp" => "awarded"} =
               submit.("for plant in range(3):\n    water(plant)\n")

      assert %{"correct" => true, "xp" => "duplicate"} =
               submit.("for p in range(3):\n    water(p)")
    end

    test "complete is for stories; submit is for exercises and code", %{conn: conn} = ctx do
      user = as_user(conn, ctx.user)

      assert json_response(post(user, "/api/lessons/#{ctx.story.id}/complete"), 200) == %{
               "xp" => "awarded"
             }

      assert json_response(post(user, "/api/lessons/#{ctx.story.id}/complete"), 200) == %{
               "xp" => "duplicate"
             }

      assert json_response(post(user, "/api/lessons/#{ctx.exercise.id}/complete"), 422) ==
               %{"error" => "invalid", "errors" => %{"lesson" => ["requires an answer"]}}

      assert json_response(post(user, "/api/lessons/#{ctx.story.id}/submit", answer: "x"), 422)[
               "errors"
             ] ==
               %{"lesson" => ["has no answer to submit"]}

      for params <- [%{}, %{answer: "   "}, %{answer: 42}] do
        assert json_response(post(user, "/api/lessons/#{ctx.code.id}/submit", params), 422)[
                 "errors"
               ] ==
                 %{"answer" => ["can't be blank"]}
      end
    end

    test "notes (≤ 4000) and draft (≤ 2000) are saved", %{conn: conn} = ctx do
      user = as_user(conn, ctx.user)
      path = "/api/lessons/#{ctx.code.id}"

      assert response(put(user, path <> "/notes", notes: String.duplicate("é", 4000)), 204) == ""
      assert response(put(user, path <> "/draft", draft: "for p in range(3):"), 204) == ""

      assert %{"progress" => %{"notes" => notes, "draft" => "for p in range(3):"}} =
               json_response(get(user, path), 200)

      assert String.length(notes) == 4000

      assert json_response(put(user, path <> "/notes", notes: String.duplicate("a", 4001)), 422)[
               "errors"
             ] ==
               %{"notes" => ["should be at most 4000 character(s)"]}

      assert json_response(put(user, path <> "/draft", draft: String.duplicate("a", 2001)), 422)[
               "errors"
             ] ==
               %{"draft" => ["should be at most 2000 character(s)"]}

      assert json_response(put(user, path <> "/notes", %{}), 422)["errors"] == %{
               "notes" => ["must be a string"]
             }

      assert response(put(user, path <> "/notes", notes: ""), 204)
    end

    test "unknown or malformed lesson ids are 404", %{conn: conn, user: user} do
      for id <- [Ecto.UUID.generate(), "nope", "1"] do
        assert json_response(get(as_user(conn, user), "/api/lessons/#{id}"), 404) == %{
                 "error" => "not_found"
               }

        assert json_response(
                 post(as_user(conn, user), "/api/lessons/#{id}/submit", answer: "x"),
                 404
               )
      end
    end
  end

  describe "premium adventures" do
    setup do
      premium =
        adventure_fixture(%{title: "La Machine de l'alchimiste", premium: true}, [[%{}, quiz()]])

      %{premium: premium, premium_lesson: hd(lessons_of(premium))}
    end

    test "free member: detail visible with lessons listed, everything else 402",
         %{conn: conn} = ctx do
      stub_billing("free", "none")
      user = as_user(conn, ctx.user)

      body = json_response(get(user, "/api/adventures/#{ctx.premium.slug}"), 200)

      assert %{
               "access" => "premium_required",
               "premium" => true,
               "chapters" => [%{"lessons" => [_, _]}]
             } = body

      lesson = "/api/lessons/#{ctx.premium_lesson.id}"

      for conn <- [
            post(user, "/api/adventures/#{ctx.premium.slug}/enroll"),
            get(user, lesson),
            post(user, lesson <> "/submit", answer: "x"),
            post(user, lesson <> "/complete"),
            put(user, lesson <> "/notes", notes: "x"),
            put(user, lesson <> "/draft", draft: "x")
          ] do
        assert json_response(conn, 402) == %{"error" => "premium_required"}
      end

      assert %{"enrolled" => false} =
               json_response(get(user, "/api/adventures/#{ctx.premium.slug}"), 200)
    end

    test "premium member (per billing) gets in", %{conn: conn} = ctx do
      stub_billing("premium")
      user = as_user(conn, ctx.user)

      assert %{"access" => "open"} =
               json_response(get(user, "/api/adventures/#{ctx.premium.slug}"), 200)

      assert json_response(post(user, "/api/adventures/#{ctx.premium.slug}/enroll"), 200) == %{
               "enrolled" => true
             }

      assert %{"lesson" => %{"id" => id}} =
               json_response(get(user, "/api/lessons/#{ctx.premium_lesson.id}"), 200)

      assert id == ctx.premium_lesson.id
      assert json_response(post(user, "/api/lessons/#{id}/complete"), 200) == %{"xp" => "awarded"}
    end

    test "billing down: premium refused with 503, free content still served",
         %{conn: conn} = ctx do
      stub_billing_down()
      user = as_user(conn, ctx.user)

      assert json_response(get(user, "/api/lessons/#{ctx.premium_lesson.id}"), 503) == %{
               "error" => "entitlements_unavailable"
             }

      assert json_response(post(user, "/api/adventures/#{ctx.premium.slug}/enroll"), 503) == %{
               "error" => "entitlements_unavailable"
             }

      assert %{"access" => "premium_required"} =
               json_response(get(user, "/api/adventures/#{ctx.premium.slug}"), 200)

      assert json_response(get(user, "/api/lessons/#{ctx.story.id}"), 200)

      assert json_response(post(user, "/api/lessons/#{ctx.story.id}/complete"), 200) == %{
               "xp" => "awarded"
             }
    end

    test "anonymous detail does not ask billing", %{conn: conn} = ctx do
      stub_billing("premium")

      assert %{"access" => "login_required"} =
               json_response(get(as_service(conn), "/api/adventures/#{ctx.premium.slug}"), 200)

      refute_received {:billing_called, _}
    end
  end

  describe "dashboard" do
    test "shape, XP, week, current adventure and recommendations", %{conn: conn} = ctx do
      adventure_fixture(%{title: "Les Gardiens des archives"})
      user = as_user(conn, ctx.user)
      json_response(post(user, "/api/lessons/#{ctx.story.id}/complete"), 200)
      json_response(get(user, "/api/lessons/#{ctx.exercise.id}"), 200)

      body = json_response(get(user, "/api/me/dashboard"), 200)

      # Forme du contrat, plus les champs additionnels de gamification (badges_*, equipped_badges, quests).
      assert Enum.sort(Map.keys(body)) ==
               ~w(badges_earned badges_total current equipped_badges into_level level per_level quests recommendations streak week xp)

      assert %{"xp" => 10, "level" => 1, "into_level" => 10, "per_level" => 150, "streak" => 1} =
               body

      today = Date.utc_today() |> Date.to_iso8601()
      assert length(body["week"]) == 7
      assert List.last(body["week"]) == %{"date" => today, "xp" => 10}

      assert body["current"] == %{
               "slug" => ctx.adventure.slug,
               "title" => "La Forêt des murmures",
               "percent" => 33,
               "resume_lesson_id" => ctx.exercise.id
             }

      assert [%{"title" => "Les Gardiens des archives"} = card] = body["recommendations"]
      assert Enum.sort(Map.keys(card)) == @card_keys
    end
  end
end
