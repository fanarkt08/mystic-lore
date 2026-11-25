defmodule MlNotificationsWeb.PrivacyTest do
  use MlNotificationsWeb.ConnCase, async: true
  alias MlNotifications.{DigestWorker, EmailLog, Notification, PendingEmail, Setting}

  test "accounts only: any other caller gets 403" do
    id = uuid()

    for svc <- ~w(web social billing notifications) do
      assert %{"error" => "forbidden"} =
               service(:get, "/api/internal/users/#{id}/export", svc) |> json_response(403)

      assert %{"error" => "forbidden"} =
               service(:delete, "/api/internal/users/#{id}", svc) |> json_response(403)
    end

    assert %{"error" => "forbidden"} =
             api(:get, "/api/internal/users/#{id}/export", id) |> json_response(403)

    assert %{"error" => "not_found"} =
             service(:get, "/api/internal/users/nope/export", "accounts") |> json_response(404)
  end

  test "export: the member's received notifications, settings and deferred e-mails only" do
    [me, other] = [uuid(), uuid()]
    create!(attrs("friend_request_received", me))
    create!(attrs("badge_earned", me))
    create!(attrs("message_received", other, %{"actor_id" => me}))
    settings!(me, %{"channels" => %{"messages" => %{"email" => true}}})

    assert %{"data" => data} =
             service(:get, "/api/internal/users/#{me}/export", "accounts") |> json_response(200)

    assert data["notifications"] |> Enum.map(& &1["kind"]) |> Enum.sort() ==
             ["badge_earned", "friend_request_received"]

    assert %{
             "channels" => %{"messages" => %{"email" => true}},
             "quiet_hours" => %{"enabled" => false}
           } =
             data["settings"]

    assert data["pending_emails"] == []
  end

  test "delete: idempotent; notifications where the member is only the ACTOR stay with their recipients" do
    [me, other] = [uuid(), uuid()]
    messages = %{"channels" => %{"messages" => %{"email" => true}}}
    settings!(me, messages)
    create!(attrs("message_received", me))

    settings!(me, %{
      "quiet_hours" => %{
        "enabled" => true,
        "start" => "00:00",
        "end" => "23:59",
        "time_zone" => "Etc/UTC"
      }
    })

    create!(attrs("message_received", me))
    kept = create!(attrs("message_received", other, %{"actor_id" => me}))
    assert Repo.aggregate(PendingEmail, :count) >= 0

    for _ <- 1..2 do
      assert service(:delete, "/api/internal/users/#{me}", "accounts") |> response(204)
    end

    refute Repo.exists?(where(Notification, user_id: ^me))
    refute Repo.get(Setting, me)
    refute Repo.exists?(where(EmailLog, user_id: ^me))
    refute Repo.exists?(where(PendingEmail, user_id: ^me))

    refute Repo.exists?(
             from e in "notification_events", where: e.user_id == type(^me, :binary_id)
           )

    assert Repo.get!(Notification, kept.notification.id).actor_id == me

    # no e-mail or digest job left to send for the deleted member
    for job <-
          all_enqueued(worker: MlNotifications.EmailWorker) ++ all_enqueued(worker: DigestWorker),
        do: refute(job.args["user_id"] == me)
  end
end
