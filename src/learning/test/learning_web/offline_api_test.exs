defmodule MlLearningWeb.OfflineApiTest do
  @moduledoc "Leçons hors ligne : paquet, expiration, révision et rejeu idempotent."
  use MlLearningWeb.ConnCase, async: true
  alias MlLearning.Repo
  alias MlLearning.Catalog.Lesson
  alias MlLearning.Offline.Action
  alias MlLearning.Progress.{LessonProgress, XpEvent}
  import Ecto.Query

  setup do
    premium =
      adventure_fixture(%{premium: true, title: "La Machine de l'alchimiste"}, [
        [%{title: "Le fourneau froid", body: "The engine is cold."}, quiz(), coding()]
      ])

    free =
      adventure_fixture(%{title: "La Forêt des murmures"}, [[%{title: "Le bosquet se réveille"}]])

    [story, exercise, code] = lessons_of(premium)
    [free_story] = lessons_of(free)
    %{story: story, exercise: exercise, code: code, free_story: free_story, user: user_id()}
  end

  defp in_days(n), do: DateTime.add(DateTime.utc_now(:second), n, :day)

  defp package(conn, user, lesson),
    do: get(as_user(conn, user), "/api/lessons/#{lesson.id}/offline")

  defp submit(conn, user, lesson, body),
    do: post(as_user(conn, user), "/api/lessons/#{lesson.id}/submit", body)

  defp complete(conn, user, lesson, body),
    do: post(as_user(conn, user), "/api/lessons/#{lesson.id}/complete", body)

  defp progress(user, lesson),
    do: Repo.get_by(LessonProgress, user_id: user, lesson_id: lesson.id)

  defp xp_events(user),
    do: Repo.all(from e in XpEvent, where: e.user_id == ^user, select: e.ref_key)

  # billing publie {:entitlements_changed, …} : learning oublie aussitôt son cache de 30 s
  defp entitlements_changed(user, plan) do
    send(MlLearning.Entitlements, {:entitlements_changed, user, plan})
    _ = :sys.get_state(MlLearning.Entitlements)
  end

  describe "package" do
    test "a premium story: public content only, the member, the dates, the lesson's revision",
         ctx do
      stub_billing("premium", "active", in_days(20))
      conn = package(ctx.conn, ctx.user, ctx.story)

      assert %{"package" => package} = json_response(conn, 200)

      assert %{
               "lesson" => %{
                 "id" => id,
                 "kind" => "story",
                 "title" => "Le fourneau froid",
                 "body" => "The engine is cold.",
                 "revision" => 1,
                 "revised_at" => _,
                 "xp_reward" => 10
               },
               "adventure" => %{"title" => "La Machine de l'alchimiste"},
               "member_id" => member,
               "downloaded_at" => downloaded,
               "expires_by" => "max_days",
               "max_days" => 14
             } = package

      assert {id, member} == {ctx.story.id, ctx.user}
      {:ok, downloaded, _} = DateTime.from_iso8601(downloaded)
      {:ok, expires, _} = DateTime.from_iso8601(package["expires_at"])
      assert DateTime.diff(expires, downloaded, :day) == 14
      # le téléchargement n'inscrit pas et ne déplace pas la « dernière leçon »
      refute progress(ctx.user, ctx.story)
    end

    test "an exercise: question and choices, NEVER the answer, its explanation or its hint",
         ctx do
      stub_billing("vip", "active", in_days(30))
      conn = package(ctx.conn, ctx.user, ctx.exercise)
      body = json_response(conn, 200)

      assert body["package"]["lesson"]["content"] == %{
               "question" => "What does range(3) produce?",
               "choices" => ["1, 2, 3", "0, 1, 2", "3, 2, 1"]
             }

      refute conn.resp_body =~ "solution"
      refute conn.resp_body =~ "stops before 3"
      refute conn.resp_body =~ "Counting starts at zero"
      refute Map.has_key?(body["package"]["lesson"], "solution")
    end

    test "the expiry never passes the end of the paid period", ctx do
      period_end = in_days(3)
      stub_billing("premium", "active", period_end)

      assert %{"package" => %{"expires_at" => expires, "expires_by" => "period_end"}} =
               json_response(package(ctx.conn, ctx.user, ctx.exercise), 200)

      assert expires == DateTime.to_iso8601(period_end)
    end

    test "refused without a paid plan (402), billing unreachable (503), no paid period in progress (409)",
         ctx do
      stub_billing("free", "none")

      assert json_response(package(ctx.conn, ctx.user, ctx.story), 402) == %{
               "error" => "premium_required"
             }

      stub_billing_down()

      assert json_response(package(ctx.conn, ctx.user, ctx.story), 503) == %{
               "error" => "entitlements_unavailable"
             }

      # a premium plan whose period end is unknown, or already past (grace of a late payment)
      for period_end <- [nil, in_days(-1)] do
        stub_billing("premium", "past_due", period_end)

        assert json_response(package(ctx.conn, ctx.user, ctx.story), 409) == %{
                 "error" => "no_paid_period"
               }
      end
    end

    test "only premium stories and quizzes are offered (422 otherwise), unknown lessons are 404",
         ctx do
      stub_billing("premium", "active", in_days(20))

      for lesson <- [ctx.code, ctx.free_story] do
        assert json_response(package(ctx.conn, ctx.user, lesson), 422) == %{
                 "error" => "offline_unavailable"
               }
      end

      assert json_response(
               get(as_user(ctx.conn, ctx.user), "/api/lessons/#{Ecto.UUID.generate()}/offline"),
               404
             ) == %{"error" => "not_found"}
    end

    test "the lesson itself says whether it can be downloaded, with its revision", ctx do
      stub_billing("premium", "active", in_days(20))

      assert %{"offline" => %{"available" => true, "revision" => 1, "max_days" => 14}} =
               json_response(
                 get(as_user(ctx.conn, ctx.user), "/api/lessons/#{ctx.exercise.id}"),
                 200
               )

      assert %{"offline" => %{"available" => false}} =
               json_response(get(as_user(ctx.conn, ctx.user), "/api/lessons/#{ctx.code.id}"), 200)
    end
  end

  describe "revision" do
    test "kept by the database: +1 when the statement changes, unchanged by an identical write",
         ctx do
      lesson = Repo.get!(Lesson, ctx.exercise.id)
      assert lesson.revision == 1

      lesson = lesson |> Ecto.Changeset.change(xp_reward: 30, position: 9) |> Repo.update!()
      assert lesson.revision == 1

      lesson =
        lesson
        |> Ecto.Changeset.change(
          content: Map.put(lesson.content, "question", "What is range(3)?")
        )
        |> Repo.update!()

      assert lesson.revision == 2

      # an upsert like the seeds' (every column rewritten with the same statement) keeps it
      same =
        Map.take(lesson, [:chapter_id, :position, :title, :kind, :body, :content, :solution])

      Repo.insert!(struct(Lesson, Map.put(same, :xp_reward, 30)),
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:chapter_id, :position]
      )

      assert Repo.get!(Lesson, lesson.id).revision == 2

      lesson |> Ecto.Changeset.change(solution: %{"answer" => "1, 2, 3"}) |> Repo.update!()
      assert Repo.get!(Lesson, lesson.id).revision == 3
    end
  end

  describe "replayed actions (idempotency key)" do
    setup do
      stub_billing("premium", "active", in_days(20))
      :ok
    end

    test "the same key gives the same answer once: one attempt, XP once, nothing counted twice",
         ctx do
      key = Ecto.UUID.generate()
      body = %{answer: "1", idempotency_key: key, revision: 1}

      first = json_response(submit(ctx.conn, ctx.user, ctx.exercise, body), 200)

      assert %{
               "correct" => true,
               "xp" => "awarded",
               "xp_reward" => 20,
               "replayed" => false,
               "feedback" => "range(3) starts at 0 and stops before 3."
             } = first

      again = json_response(submit(ctx.conn, ctx.user, ctx.exercise, body), 200)
      assert again == Map.put(first, "replayed", true)

      assert %{attempts: 1, status: "completed"} = progress(ctx.user, ctx.exercise)
      assert xp_events(ctx.user) == ["lesson:#{ctx.exercise.id}"]
      assert Repo.aggregate(from(a in Action, where: a.user_id == ^ctx.user), :count) == 1
    end

    test "a wrong answer is graded by the server (hint, no XP), a new key is a new attempt",
         ctx do
      wrong = %{answer: "0", idempotency_key: Ecto.UUID.generate(), revision: 1}

      assert %{"correct" => false, "xp" => "none", "feedback" => "Counting starts at zero."} =
               json_response(submit(ctx.conn, ctx.user, ctx.exercise, wrong), 200)

      right = %{answer: "0, 1, 2", idempotency_key: Ecto.UUID.generate(), revision: 1}

      assert %{"correct" => true, "xp" => "awarded"} =
               json_response(submit(ctx.conn, ctx.user, ctx.exercise, right), 200)

      assert %{attempts: 2} = progress(ctx.user, ctx.exercise)
    end

    test "a story completed offline: XP once, replay counted nowhere", ctx do
      key = Ecto.UUID.generate()
      body = %{idempotency_key: key, revision: 1}

      assert %{"xp" => "awarded", "xp_reward" => 10, "replayed" => false} =
               json_response(complete(ctx.conn, ctx.user, ctx.story, body), 200)

      assert %{"xp" => "awarded", "replayed" => true} =
               json_response(complete(ctx.conn, ctx.user, ctx.story, body), 200)

      # another key for the same story: completed already, the XP stays single
      assert %{"xp" => "duplicate", "replayed" => false} =
               json_response(
                 complete(ctx.conn, ctx.user, ctx.story, %{
                   idempotency_key: Ecto.UUID.generate(),
                   revision: 1
                 }),
                 200
               )

      assert xp_events(ctx.user) == ["lesson:#{ctx.story.id}"]
    end

    test "the lesson changed since the download: refused with its revision, nothing counted or kept",
         ctx do
      ctx.exercise
      |> Ecto.Changeset.change(body: "The warden asks a NEW riddle.")
      |> Repo.update!()

      conn =
        submit(ctx.conn, ctx.user, ctx.exercise, %{
          answer: "1",
          idempotency_key: Ecto.UUID.generate(),
          revision: 1
        })

      assert json_response(conn, 409) == %{"error" => "lesson_changed", "revision" => 2}
      refute progress(ctx.user, ctx.exercise)
      assert xp_events(ctx.user) == []
      assert Repo.aggregate(from(a in Action, where: a.user_id == ^ctx.user), :count) == 0
    end

    test "a key reused for another answer or lesson is refused; malformed keys and revisions are 422",
         ctx do
      key = Ecto.UUID.generate()

      assert %{"replayed" => false} =
               json_response(
                 submit(ctx.conn, ctx.user, ctx.exercise, %{
                   answer: "0",
                   idempotency_key: key,
                   revision: 1
                 }),
                 200
               )

      assert json_response(
               submit(ctx.conn, ctx.user, ctx.exercise, %{
                 answer: "1",
                 idempotency_key: key,
                 revision: 1
               }),
               422
             ) == %{"error" => "idempotency_key_reused"}

      assert json_response(
               complete(ctx.conn, ctx.user, ctx.story, %{idempotency_key: key, revision: 1}),
               422
             ) == %{"error" => "idempotency_key_reused"}

      assert %{"errors" => %{"idempotency_key" => ["must be a UUID"]}} =
               json_response(
                 submit(ctx.conn, ctx.user, ctx.exercise, %{answer: "1", idempotency_key: "k1"}),
                 422
               )

      assert %{"errors" => %{"revision" => ["must be a positive integer"]}} =
               json_response(
                 submit(ctx.conn, ctx.user, ctx.exercise, %{
                   answer: "1",
                   idempotency_key: Ecto.UUID.generate(),
                   revision: "1"
                 }),
                 422
               )

      assert %{"errors" => %{"idempotency_key" => ["is required with a revision"]}} =
               json_response(
                 submit(ctx.conn, ctx.user, ctx.exercise, %{answer: "1", revision: 1}),
                 422
               )

      # one attempt only: the refused requests counted nothing
      assert %{attempts: 1} = progress(ctx.user, ctx.exercise)
    end

    test "a member's key never answers for another member", ctx do
      key = Ecto.UUID.generate()
      other = user_id()
      body = %{answer: "1", idempotency_key: key, revision: 1}

      assert %{"replayed" => false} =
               json_response(submit(ctx.conn, ctx.user, ctx.exercise, body), 200)

      assert %{"replayed" => false, "xp" => "awarded"} =
               json_response(submit(ctx.conn, other, ctx.exercise, body), 200)
    end

    test "access lost before the synchronization: 402, nothing counted", ctx do
      stub_billing("free", "canceled", in_days(-2))
      entitlements_changed(ctx.user, "free")

      conn =
        submit(ctx.conn, ctx.user, ctx.exercise, %{
          answer: "1",
          idempotency_key: Ecto.UUID.generate(),
          revision: 1
        })

      assert json_response(conn, 402) == %{"error" => "premium_required"}
      refute progress(ctx.user, ctx.exercise)
    end

    test "no client date is read: the XP counts on the day of the synchronization", ctx do
      body = %{
        idempotency_key: Ecto.UUID.generate(),
        revision: 1,
        answered_at: "2020-01-01T00:00:00Z",
        inserted_at: "2020-01-01T00:00:00Z"
      }

      assert %{"xp" => "awarded"} =
               json_response(complete(ctx.conn, ctx.user, ctx.story, body), 200)

      [event] = Repo.all(from e in XpEvent, where: e.user_id == ^ctx.user)
      assert DateTime.to_date(event.inserted_at) == Date.utc_today()
    end
  end
end
