defmodule MlNotifications.EmailsTest do
  use MlNotifications.DataCase, async: true
  alias MlNotifications.{DigestWorker, EmailLog, EmailWorker, Inbox, Notification, PendingEmail}

  # 15 January 2026, 12:00 in Paris (UTC+1): outside 22:00–07:00
  @noon ~U[2026-01-15 11:00:00.000000Z]
  # 23:00 in Paris: inside
  @night ~U[2026-01-15 22:00:00.000000Z]

  defp messages_by_email(me),
    do: settings!(me, %{"channels" => %{"messages" => %{"email" => true}}})

  defp quiet!(me, now) do
    settings!(
      me,
      %{
        "quiet_hours" => %{
          "enabled" => true,
          "start" => "22:00",
          "end" => "07:00",
          "time_zone" => "Europe/Paris"
        }
      },
      now
    )
  end

  defp message(me, conversation, i, at \\ nil) do
    body =
      attrs("message_received", me, %{"conversation_id" => conversation, "event_id" => "m#{i}"})

    if at, do: Map.put(body, "occurred_at", DateTime.to_iso8601(at)), else: body
  end

  test "security: e-mailed at once, even in quiet hours, never limited" do
    me = uuid()
    quiet!(me, @night)

    for _ <- 1..3 do
      assert %{email: "queued"} = create!(attrs("password_changed", me), @night)
    end

    jobs = all_enqueued(worker: EmailWorker)
    assert length(jobs) == 3

    assert Enum.all?(
             jobs,
             &(&1.args["mandatory"] and
                 DateTime.compare(&1.scheduled_at, DateTime.utc_now()) != :gt)
           )

    assert Repo.aggregate(PendingEmail, :count) == 0
  end

  test "e-mail already sent by accounts (address change, sanctions, support reply): the center never sends a second one" do
    me = uuid()
    assert %{status: "created", email: "none"} = create!(attrs("email_changed", me))
    assert %{status: "created", email: "none"} = create!(attrs("sanction_issued", me))

    # la réponse du staff est déjà partie par e-mail (accounts) : le centre n'ajoute que l'entrée in-app
    assert %{status: "created", email: "none"} = create!(attrs("support_replied", me))
    refute_enqueued(worker: EmailWorker)
  end

  test "support_replied: accounts only, the request id as subject, nothing else accepted" do
    me = uuid()
    request = uuid()

    assert {:ok, %{status: "created"}} =
             Inbox.create(
               "accounts",
               attrs("support_replied", me, %{"params" => %{"request_id" => request}}),
               DateTime.utc_now()
             )

    assert %{subject_type: "support_request", subject_id: ^request} =
             Repo.get_by!(Notification, user_id: me)

    assert {:error, :forbidden} =
             Inbox.create("social", attrs("support_replied", uuid()), DateTime.utc_now())

    # never a text, an address or a link: unknown parameters are refused
    assert {:error, {:invalid, %{params: _}}} =
             Inbox.create(
               "accounts",
               attrs("support_replied", uuid(), %{
                 "params" => %{"request_id" => uuid(), "body" => "the reply text"}
               }),
               DateTime.utc_now()
             )
  end

  test "optional category: after the delay, one per conversation and per hour" do
    me = uuid()
    messages_by_email(me)
    conversation = uuid()

    assert %{email: "queued"} = create!(message(me, conversation, 1), @noon)
    assert %{email: "none"} = create!(message(me, conversation, 2), DateTime.add(@noon, 1800))
    # another conversation: its own e-mail
    assert %{email: "queued"} = create!(message(me, uuid(), 3), DateTime.add(@noon, 1900))
    # one hour later the same conversation may e-mail again
    assert %{email: "queued"} = create!(message(me, conversation, 4), DateTime.add(@noon, 3601))

    assert length(all_enqueued(worker: EmailWorker)) == 3
  end

  test "daily cap of 20 e-mails per member (security and mandatory billing excepted)" do
    me = uuid()
    messages_by_email(me)

    for i <- 1..20, do: assert(%{email: "queued"} = create!(message(me, uuid(), i), @noon))
    assert %{email: "none"} = create!(message(me, uuid(), 21), @noon)
    assert %{email: "queued"} = create!(attrs("password_changed", me), @noon)
    assert %{email: "queued"} = create!(attrs("payment_failed", me), @noon)
  end

  test "worker: asks accounts with the latest state, marks the log once confirmed" do
    me = uuid()
    messages_by_email(me)
    conversation = uuid()
    create!(message(me, conversation, 1), @noon)
    create!(message(me, conversation, 2), DateTime.add(@noon, 10))
    [job] = all_enqueued(worker: EmailWorker)

    assert :ok = perform_job(EmailWorker, job.args)
    assert_received {:email_requested, ^me, body}

    assert %{
             "kind" => "message_received",
             "count" => 2,
             "params" => %{"conversation_kind" => "direct"}
           } = body

    refute Map.has_key?(body, "email") or Map.has_key?(body, "body")
    assert [%EmailLog{sent_at: %DateTime{}}] = Repo.all(EmailLog)
  end

  test "worker: cancelled when read in the meantime, or the channel turned off; accounts refusal is final" do
    me = uuid()
    messages_by_email(me)
    create!(message(me, uuid(), 1), @noon)
    [job] = all_enqueued(worker: EmailWorker)
    Repo.update_all(Notification, set: [read_at: @noon])
    assert {:cancel, "read"} = perform_job(EmailWorker, job.args)
    refute_received {:email_requested, _, _}

    Repo.update_all(Notification, set: [read_at: nil])
    settings!(me, %{"channels" => %{"messages" => %{"email" => false}}})
    assert {:cancel, "disabled"} = perform_job(EmailWorker, job.args)

    messages_by_email(me)
    fake_accounts({409, %{"error" => "not_deliverable"}})
    assert {:cancel, "not_deliverable"} = perform_job(EmailWorker, job.args)

    fake_accounts(:unavailable)
    assert {:error, :unavailable} = perform_job(EmailWorker, job.args)
    assert [%EmailLog{sent_at: nil}] = Repo.all(EmailLog)
  end

  test "quiet hours: deferred, then ONE digest at their end (grouped by conversation, read ones dropped)" do
    me = uuid()
    messages_by_email(me)
    settings!(me, %{"channels" => %{"friends" => %{"email" => true}}})
    quiet!(me, @night)
    [c1, c2] = [uuid(), uuid()]

    assert %{email: "deferred", notification: n1} = create!(message(me, c1, 1), @night)
    assert %{email: "deferred"} = create!(message(me, c1, 2), DateTime.add(@night, 60))

    assert %{email: "deferred", notification: n2} =
             create!(message(me, c2, 3), DateTime.add(@night, 120))

    assert %{email: "deferred"} =
             create!(attrs("friend_request_received", me), DateTime.add(@night, 180))

    refute_enqueued(worker: EmailWorker)
    assert Repo.aggregate(PendingEmail, :count) == 4

    # one digest, at 07:00 in Paris (06:00 UTC)
    assert [digest] = all_enqueued(worker: DigestWorker)
    assert digest.scheduled_at == ~U[2026-01-16 06:00:00.000000Z]
    assert digest.args == %{"user_id" => me}

    # visible through the settings API (no need to wait for the morning)
    assert %{"pending_digest" => %{"count" => 4, "send_at" => send_at}} =
             MlNotifications.Preferences.to_map(MlNotifications.Preferences.get(me), @night)

    assert send_at == ~U[2026-01-16 06:00:00.000000Z]

    # the second conversation was read in the app before the morning: not in the digest
    {:ok, _} = Inbox.read(me, n2.id)
    refute n1.read_at

    # quiet hours over (they were turned off): the digest goes out
    settings!(me, %{"quiet_hours" => %{"enabled" => false}})
    assert :ok = perform_job(DigestWorker, %{"user_id" => me})
    assert_received {:email_requested, ^me, %{"kind" => "digest", "items" => items, "total" => 2}}

    assert [
             %{
               "kind" => "message_received",
               "count" => 2,
               "params" => %{"conversation_id" => ^c1}
             },
             %{"kind" => "friend_request_received", "count" => 1}
           ] = items

    assert Repo.aggregate(PendingEmail, :count) == 0
    refute_received {:email_requested, _, _}
  end

  test "digest still in quiet hours is snoozed; accounts down keeps the deferred e-mails" do
    me = uuid()
    messages_by_email(me)
    # quiet hours all day long around now, in UTC
    now = DateTime.utc_now()
    start = now |> DateTime.add(-3600) |> Calendar.strftime("%H:%M")
    finish = now |> DateTime.add(3600) |> Calendar.strftime("%H:%M")

    settings!(me, %{
      "quiet_hours" => %{
        "enabled" => true,
        "start" => start,
        "end" => finish,
        "time_zone" => "Etc/UTC"
      }
    })

    assert %{email: "deferred"} = create!(message(me, uuid(), 1))
    assert {:snooze, seconds} = perform_job(DigestWorker, %{"user_id" => me})
    assert seconds in 3000..3600

    settings!(me, %{"quiet_hours" => %{"enabled" => false}})
    fake_accounts(:unavailable)
    assert {:error, :unavailable} = perform_job(DigestWorker, %{"user_id" => me})
    assert Repo.aggregate(PendingEmail, :count) == 1
  end

  test "turning quiet hours off reschedules the pending digest to now" do
    me = uuid()
    messages_by_email(me)
    quiet!(me, @night)
    create!(message(me, uuid(), 1), @night)
    [%{scheduled_at: tomorrow}] = all_enqueued(worker: DigestWorker)
    settings!(me, %{"quiet_hours" => %{"enabled" => false}}, DateTime.add(@night, 60))
    assert [%{scheduled_at: at}] = all_enqueued(worker: DigestWorker)
    assert DateTime.compare(at, tomorrow) == :lt
  end
end
