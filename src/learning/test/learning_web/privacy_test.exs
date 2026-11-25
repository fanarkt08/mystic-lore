defmodule MlLearningWeb.PrivacyTest do
  use MlLearningWeb.ConnCase, async: true
  import Ecto.Query, only: [from: 2]
  alias MlLearning.Repo
  alias MlLearning.Catalog.Adventure
  alias MlLearning.Gamification.UserBadge
  alias MlLearning.Offline.Action
  alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}

  defp caller(conn, service),
    do: put_req_header(conn, "authorization", "Bearer " <> MlShared.InternalToken.sign(service))

  defp accounts(conn), do: caller(conn, "accounts")

  # Un membre avec de la progression, une note, de l'XP et un badge dans `adventure`.
  defp activity!(user_id, adventure, note) do
    [lesson | _] = lessons_of(adventure)

    Repo.insert!(%Enrollment{
      user_id: user_id,
      adventure_id: adventure.id,
      last_lesson_id: lesson.id
    })

    Repo.insert!(%LessonProgress{
      user_id: user_id,
      lesson_id: lesson.id,
      status: "completed",
      attempts: 1,
      notes: note,
      completed_at: DateTime.utc_now(:second)
    })

    xp_event(user_id, "lesson:#{lesson.id}", 10)

    Repo.insert!(%UserBadge{
      user_id: user_id,
      badge_id: badge_fixture().id,
      earned_at: DateTime.utc_now(:second)
    })

    # reçu d'une action synchronisée depuis une leçon hors ligne
    Repo.insert!(%Action{
      user_id: user_id,
      key: Ecto.UUID.generate(),
      lesson_id: lesson.id,
      action: "complete",
      request_hash: "h",
      response: %{"xp" => "awarded", "xp_reward" => 10}
    })
  end

  setup do
    me = user_id()
    other = user_id()
    adventure = adventure_fixture(%{author_id: me, source: nil})
    activity!(me, adventure, "My secret note")
    activity!(other, adventure, "Someone else's note")
    %{me: me, other: other, adventure: adventure}
  end

  test "only the accounts service may call them (403 otherwise)", %{conn: conn, me: me} do
    for conn <- [as_user(conn, me), as_service(conn), caller(conn, "studio")] do
      assert %{"error" => "forbidden"} =
               conn |> get("/api/internal/users/#{me}/export") |> json_response(403)

      assert conn |> delete("/api/internal/users/#{me}") |> json_response(403)
    end

    assert conn |> get("/api/internal/users/#{me}/export") |> json_response(401)
    assert Repo.aggregate(XpEvent, :count) == 2
  end

  test "export holds only this member's progress, notes, XP, badges and authored adventures", %{
    conn: conn,
    me: me,
    adventure: adventure
  } do
    assert %{"data" => data} =
             conn |> accounts() |> get("/api/internal/users/#{me}/export") |> json_response(200)

    assert data["xp_total"] == 10
    assert data["level"] == 1
    assert [%{"adventure" => slug}] = data["enrollments"]
    assert slug == adventure.slug
    assert [%{"notes" => "My secret note", "status" => "completed"}] = data["lesson_progress"]
    assert [%{"amount" => 10, "ref_key" => "lesson:" <> _}] = data["xp_events"]
    assert [%{"badge" => "badge-" <> _}] = data["badges"]

    assert [%{"action" => "complete", "result" => %{"xp" => "awarded"}, "lesson" => _}] =
             data["offline_actions"]

    assert data["authored_adventures"] == [
             %{"slug" => adventure.slug, "title" => adventure.title}
           ]

    refute inspect(data) =~ "Someone else"

    assert conn |> accounts() |> get("/api/internal/users/nope/export") |> json_response(404)
  end

  test "DELETE removes the member's data, keeps the adventure without author, idempotent", %{
    conn: conn,
    me: me,
    other: other,
    adventure: adventure
  } do
    assert conn |> accounts() |> delete("/api/internal/users/#{me}") |> response(204)

    for schema <- [Enrollment, LessonProgress, XpEvent, UserBadge, Action] do
      assert Repo.all(from x in schema, where: x.user_id == ^me) == []
      assert [_] = Repo.all(from x in schema, where: x.user_id == ^other)
    end

    assert %Adventure{author_id: nil} = Repo.get!(Adventure, adventure.id)

    assert build_conn() |> accounts() |> delete("/api/internal/users/#{me}") |> response(204)

    assert %{"data" => %{"xp_total" => 0, "lesson_progress" => [], "authored_adventures" => []}} =
             build_conn()
             |> accounts()
             |> get("/api/internal/users/#{me}/export")
             |> json_response(200)
  end
end
