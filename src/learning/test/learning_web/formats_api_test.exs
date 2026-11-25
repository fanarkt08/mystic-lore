defmodule MlLearningWeb.FormatsApiTest do
  @moduledoc "API des formats vidéo, simulation et mini-jeu : corrigés côté serveur, solution jamais exposée, XP unique."
  use MlLearningWeb.ConnCase, async: true
  import Ecto.Query
  alias MlLearning.Repo
  alias MlLearning.Progress.{Enrollment, LessonProgress}

  setup do
    adventure =
      adventure_fixture(%{title: "L'Atlas céleste"}, [
        [video_lesson(), orbit_lesson(), reaction_lesson()],
        [sequence_lesson(), constellation_lesson()]
      ])

    [video, orbit, reaction, sequence, constellation] = lessons_of(adventure)

    %{
      user: user_id(),
      video: video,
      orbit: orbit,
      reaction: reaction,
      sequence: sequence,
      constellation: constellation
    }
  end

  defp get_lesson(conn, user, lesson),
    do: conn |> as_user(user) |> get("/api/lessons/#{lesson.id}") |> json_response(200)

  defp post_json(conn, user, path, body), do: conn |> as_user(user) |> post(path, body)

  describe "video" do
    test "content exposes the media, captions and transcript; completion needs the evidence", %{
      conn: conn,
      user: user,
      video: video
    } do
      %{"lesson" => %{"kind" => "video", "content" => content}} = get_lesson(conn, user, video)

      assert %{
               "video" => %{"src" => "/media/lessons/sky.webm", "type" => "video/webm"},
               "captions" => [%{"lang" => "en", "src" => "/media/lessons/sky.en.vtt"}],
               "transcript" => "Every star" <> _,
               "duration_s" => 30
             } = content

      path = "/api/lessons/#{video.id}/complete"

      for body <- [
            %{},
            %{"watched_percent" => 50},
            %{"watched_percent" => "90"},
            %{"transcript_opened" => "yes"}
          ] do
        assert %{"errors" => %{"watched_percent" => _}} =
                 post_json(conn, user, path, body) |> json_response(422)
      end

      assert %{"xp" => "awarded"} =
               post_json(conn, user, path, %{"watched_percent" => 85}) |> json_response(200)

      assert %{"xp" => "duplicate"} =
               post_json(conn, user, path, %{"transcript_opened" => true}) |> json_response(200)

      other = user_id()

      assert %{"xp" => "awarded"} =
               post_json(conn, other, path, %{"transcript_opened" => true}) |> json_response(200)

      assert %{"errors" => %{"lesson" => ["has no answer to submit"]}} =
               post_json(conn, user, "/api/lessons/#{video.id}/submit", %{"answer" => "x"})
               |> json_response(422)
    end
  end

  describe "simulation" do
    test "the criterion is never exposed", %{conn: conn, user: user, orbit: orbit} do
      %{"lesson" => %{"content" => content}} = body = get_lesson(conn, user, orbit)
      assert %{"model" => "orbit", "params" => %{"velocity" => %{"min" => 4.0}}} = content
      refute Jason.encode!(body) =~ "eccentricity"
    end

    test "simulate: frames ≤ 200, columns, metrics, description; no side effect", %{
      conn: conn,
      user: user,
      orbit: orbit
    } do
      body =
        post_json(conn, user, "/api/lessons/#{orbit.id}/simulate", %{
          "params" => %{"velocity" => 6.3}
        })
        |> json_response(200)

      assert %{"engine" => engine, "frames" => frames, "metrics" => metrics} = body
      assert engine in ["native", "elixir"]
      assert length(frames) in 1..200
      assert %{"eccentricity" => 0.004394, "revolutions" => 1} = metrics
      assert body["description"] =~ "full orbit"
      assert [%{"key" => "t", "label" => "Time", "unit" => "yr"} | _] = body["columns"]
      refute Repo.exists?(from e in Enrollment, where: e.user_id == ^user)
    end

    test "out-of-bounds, off-grid, unknown or non-numeric parameters → 422", %{
      conn: conn,
      user: user,
      orbit: orbit
    } do
      path = "/api/lessons/#{orbit.id}/simulate"

      for {params, field} <- [
            {%{"velocity" => 50}, "params.velocity"},
            {%{"velocity" => -1}, "params.velocity"},
            {%{"velocity" => 6.25}, "params.velocity"},
            {%{"star_mass" => "heavy"}, "params.star_mass"},
            {%{"steps" => 1_000_000}, "params.steps"}
          ] do
        assert %{"error" => "invalid", "errors" => errors} =
                 post_json(conn, user, path, %{"params" => params}) |> json_response(422)

        assert Map.has_key?(errors, field), inspect(params)
      end

      assert %{"errors" => %{"params" => _}} =
               post_json(conn, user, path, %{"params" => [1, 2]}) |> json_response(422)
    end

    test "simulate is only for simulation lessons", %{conn: conn, user: user, video: video} do
      assert %{"errors" => %{"lesson" => ["is not a simulation"]}} =
               post_json(conn, user, "/api/lessons/#{video.id}/simulate", %{"params" => %{}})
               |> json_response(422)
    end

    test "submit: wrong → none, solution → XP once; malformed answers are not attempts", %{
      conn: conn,
      user: user,
      orbit: orbit
    } do
      path = "/api/lessons/#{orbit.id}/submit"

      assert %{"correct" => false, "xp" => "none", "feedback" => feedback} =
               post_json(conn, user, path, %{"answer" => ~s({"velocity": 7.0})})
               |> json_response(200)

      assert feedback =~ "elongated"

      assert %{"errors" => %{"params.velocity" => _}} =
               post_json(conn, user, path, %{"answer" => ~s({"velocity": 99})})
               |> json_response(422)

      assert %{"errors" => %{"answer" => _}} =
               post_json(conn, user, path, %{"answer" => "fast please"}) |> json_response(422)

      assert %{"correct" => true, "xp" => "awarded"} =
               post_json(conn, user, path, %{"answer" => ~s({"velocity": 6.3, "star_mass": 1.0})})
               |> json_response(200)

      assert %{"correct" => true, "xp" => "duplicate"} =
               post_json(conn, user, path, %{"answer" => ~s({"velocity": 6.2})})
               |> json_response(200)

      assert %{attempts: 3, status: "completed"} =
               Repo.get_by!(LessonProgress, user_id: user, lesson_id: orbit.id)
    end

    test "reaction: balanced in lowest terms", %{conn: conn, user: user, reaction: reaction} do
      path = "/api/lessons/#{reaction.id}/submit"
      answer = fn h2, o2, h2o -> Jason.encode!(%{"h2" => h2, "o2" => o2, "h2o" => h2o}) end

      assert %{"correct" => false} =
               post_json(conn, user, path, %{"answer" => answer.(4, 2, 4)}) |> json_response(200)

      assert %{"correct" => true, "xp" => "awarded"} =
               post_json(conn, user, path, %{"answer" => answer.(2, 1, 2)}) |> json_response(200)

      run =
        post_json(conn, user, "/api/lessons/#{reaction.id}/simulate", %{
          "params" => %{"h2" => 2, "o2" => 1, "h2o" => 2}
        })
        |> json_response(200)

      assert %{"metrics" => %{"balanced" => true, "drift" => %{"H" => +0.0, "O" => +0.0}}} = run
      assert length(run["frames"]) == 7
    end
  end

  describe "minigame" do
    test "sequence: shuffled per learner (deterministic), never in the expected order, order never exposed",
         %{conn: conn, user: user, sequence: sequence} do
      first = get_lesson(conn, user, sequence)
      again = get_lesson(conn, user, sequence)
      items = first["lesson"]["content"]["items"]
      assert items == again["lesson"]["content"]["items"]
      assert length(items) == 5
      refute Enum.map(items, & &1["id"]) == sequence.solution["order"]
      refute Jason.encode!(first) =~ ~s("order")
      refute Jason.encode!(first) =~ ~s("solution")

      shuffles =
        for _ <- 1..6 do
          get_lesson(conn, user_id(), sequence)["lesson"]["content"]["items"]
          |> Enum.map(& &1["id"])
        end

      assert length(Enum.uniq(shuffles)) > 1
    end

    test "sequence: moves are replayed by the server; solved → score 100 and XP once", %{
      conn: conn,
      user: user,
      sequence: sequence
    } do
      start = Enum.map(get_lesson(conn, user, sequence)["lesson"]["content"]["items"], & &1["id"])
      path = "/api/lessons/#{sequence.id}/submit"

      assert %{"correct" => false, "score" => score, "xp" => "none"} =
               post_json(conn, user, path, %{"answer" => ~s({"moves": []})}) |> json_response(200)

      assert score < 100

      assert %{"errors" => %{"answer" => ["contains an impossible move"]}} =
               post_json(conn, user, path, %{
                 "answer" => Jason.encode!(%{"moves" => [%{"id" => hd(start), "dir" => "up"}]})
               })
               |> json_response(422)

      moves = solve(start, sequence.solution["order"])

      assert %{"correct" => true, "score" => 100, "xp" => "awarded", "feedback" => feedback} =
               post_json(conn, user, path, %{"answer" => Jason.encode!(%{"moves" => moves})})
               |> json_response(200)

      assert feedback =~ "right order"

      assert %{"xp" => "duplicate"} =
               post_json(conn, user, path, %{"answer" => Jason.encode!(%{"moves" => moves})})
               |> json_response(200)
    end

    test "constellation: the path must follow the expected stars in order", %{
      conn: conn,
      user: user,
      constellation: game
    } do
      %{"lesson" => %{"content" => content}} = body = get_lesson(conn, user, game)
      assert length(content["stars"]) == 4
      refute Jason.encode!(body) =~ ~s("path")
      id = Map.new(content["stars"], &{&1["name"], &1["id"]})
      path = "/api/lessons/#{game.id}/submit"
      answer = fn names -> Jason.encode!(%{"moves" => Enum.map(names, &id[&1])}) end

      assert %{"correct" => false, "score" => 50} =
               post_json(conn, user, path, %{"answer" => answer.(~w(Alpha Beta Delta Gamma))})
               |> json_response(200)

      assert %{"errors" => %{"answer" => _}} =
               post_json(conn, user, path, %{"answer" => ~s({"moves": ["nope"]})})
               |> json_response(422)

      assert %{"correct" => true, "score" => 100, "xp" => "awarded"} =
               post_json(conn, user, path, %{"answer" => answer.(~w(Alpha Beta Gamma Beta))})
               |> json_response(200)
    end

    test "premium adventure: every format route answers 402 without the entitlement", %{
      conn: conn,
      user: user
    } do
      stub_billing("free")

      premium =
        adventure_fixture(%{premium: true}, [[orbit_lesson(), sequence_lesson(), video_lesson()]])

      [orbit, game, video] = lessons_of(premium)

      for {path, body} <- [
            {"/api/lessons/#{orbit.id}/simulate", %{"params" => %{}}},
            {"/api/lessons/#{orbit.id}/submit", %{"answer" => ~s({"velocity": 6.3})}},
            {"/api/lessons/#{game.id}/submit", %{"answer" => ~s({"moves": []})}},
            {"/api/lessons/#{video.id}/complete", %{"transcript_opened" => true}}
          ] do
        assert %{"error" => "premium_required"} =
                 post_json(conn, user, path, body) |> json_response(402)
      end

      assert conn |> as_user(user) |> get("/api/lessons/#{game.id}") |> json_response(402)
    end
  end

  # adjacent swaps (bubble sort) from `start` to `order`
  defp solve(start, order) do
    rank = order |> Enum.with_index() |> Map.new()

    {moves, _} =
      Enum.reduce(1..length(start), {[], start}, fn _, acc ->
        Enum.reduce(0..(length(start) - 2), acc, fn i, {moves, list} ->
          [a, b] = Enum.slice(list, i, 2)

          if rank[a] > rank[b],
            do:
              {moves ++ [%{"id" => b, "dir" => "up"}],
               list |> List.replace_at(i, b) |> List.replace_at(i + 1, a)},
            else: {moves, list}
        end)
      end)

    moves
  end
end
