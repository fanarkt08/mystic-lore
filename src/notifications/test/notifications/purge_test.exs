defmodule MlNotifications.PurgeTest do
  use MlNotifications.DataCase, async: true
  alias MlNotifications.{Inbox, Notification, PurgeWorker}

  test "90 days after their last event, notifications are purged (read or not)" do
    me = uuid()
    now = DateTime.utc_now()
    create!(attrs("badge_earned", me), DateTime.add(now, -91, :day))
    create!(attrs("lobby_invite", me), DateTime.add(now, -89, :day))
    assert :ok = perform_job(PurgeWorker, %{})
    assert [%Notification{kind: "lobby_invite"}] = Repo.all(Notification)
  end

  test "at most 500 per member: the oldest go, at creation and by the purge" do
    me = uuid()
    other = uuid()
    t0 = ~U[2026-11-01 00:00:00.000000Z]

    rows =
      for i <- 1..501 do
        at = DateTime.add(t0, i, :second)

        %{
          id: Ecto.UUID.generate(),
          user_id: me,
          category: "learning",
          kind: "badge_earned",
          params: %{},
          dedupe_key: "k#{i}",
          count: 1,
          last_event_at: at,
          inserted_at: at,
          updated_at: at
        }
      end

    Repo.insert_all(Notification, rows)
    create!(attrs("badge_earned", other))
    assert %{capped: 1} = Inbox.purge(DateTime.add(t0, 10, :day))
    assert Repo.aggregate(where(Notification, user_id: ^me), :count) == 500
    refute Repo.exists?(where(Notification, user_id: ^me, dedupe_key: "k1"))

    # a new one pushes the oldest out at once
    create!(attrs("badge_earned", me), DateTime.add(t0, 600, :second))
    assert Repo.aggregate(where(Notification, user_id: ^me), :count) == 500
    refute Repo.exists?(where(Notification, user_id: ^me, dedupe_key: "k2"))
    assert Repo.aggregate(where(Notification, user_id: ^other), :count) == 1
  end

  test "processed occurrences (30 days) and read marks (7 days) are purged too" do
    me = uuid()
    now = DateTime.utc_now()
    create!(attrs("badge_earned", me, %{"event_id" => "old"}), DateTime.add(now, -31, :day))
    create!(attrs("badge_earned", me, %{"event_id" => "recent"}), now)

    Inbox.read_by_key("social", %{
      "user_id" => me,
      "dedupe_key" => "conversation:x",
      "read_at" => DateTime.to_iso8601(DateTime.add(now, -8, :day))
    })

    Inbox.purge(now)
    assert ["recent"] = Repo.all(from e in "notification_events", select: e.event_id)
    assert Repo.aggregate("notification_read_marks", :count) == 0
  end
end
