defmodule MlNotificationsWeb.InternalTest do
  use MlNotificationsWeb.ConnCase, async: true
  alias MlNotifications.{Notification, PendingEmail}

  @create "/api/internal/notifications"

  describe "producer rights" do
    test "each service creates only its own categories (403 otherwise)" do
      me = uuid()

      for {svc, kind} <- [
            {"social", "message_received"},
            {"social", "friend_request_received"},
            {"community", "community_reply"},
            {"multiplayer", "lobby_invite"},
            {"learning", "badge_earned"},
            {"studio", "review_approved"},
            {"billing", "subscription_activated"},
            {"accounts", "password_changed"},
            {"accounts", "sanction_issued"}
          ] do
        assert %{"status" => "created"} =
                 service(:post, @create, svc, attrs(kind, me)) |> json_response(201)
      end

      # a service creating another service's category, web, an unknown caller
      for {svc, kind} <- [
            {"community", "message_received"},
            {"social", "password_changed"},
            {"billing", "badge_earned"},
            {"learning", "sanction_issued"},
            {"web", "message_received"},
            {"unknown", "badge_earned"}
          ] do
        assert %{"error" => "forbidden"} =
                 service(:post, @create, svc, attrs(kind, me)) |> json_response(403)
      end

      assert Repo.aggregate(Notification, :count) == 9
    end

    test "unknown category, kind or params → 422 (nothing stored)" do
      me = uuid()

      assert %{"errors" => %{"category" => ["is invalid"]}} =
               service(:post, @create, "social", %{
                 attrs("message_received", me)
                 | "category" => "ads"
               })
               |> json_response(422)

      # a kind of another category of the same producer
      assert %{"errors" => %{"kind" => ["is invalid"]}} =
               service(:post, @create, "social", %{
                 attrs("message_received", me)
                 | "kind" => "group_added",
                   "category" => "messages"
               })
               |> json_response(422)

      assert %{"errors" => %{"kind" => ["is invalid"]}} =
               service(:post, @create, "social", %{
                 attrs("message_received", me)
                 | "kind" => "rendered"
               })
               |> json_response(422)

      bad = [
        {%{
           "params" => %{
             "conversation_id" => uuid(),
             "conversation_kind" => "direct",
             "body" => "hi"
           }
         }, %{"params" => ["has an unknown key: body"]}},
        {%{"params" => %{"conversation_kind" => "direct"}},
         %{"params" => ["is missing conversation_id"]}},
        {%{"params" => %{"conversation_id" => "nope", "conversation_kind" => "direct"}},
         %{"params" => ["has an invalid conversation_id"]}},
        {%{"params" => %{"conversation_id" => uuid(), "conversation_kind" => "channel"}},
         %{"params" => ["has an invalid conversation_kind"]}},
        {%{"actor_id" => nil}, %{"actor_id" => ["is invalid"]}},
        {%{"dedupe_key" => "has spaces"}, %{"dedupe_key" => ["is invalid"]}},
        {%{"dedupe_key" => nil}, %{"dedupe_key" => ["can't be blank"]}},
        {%{"user_id" => "x"}, %{"user_id" => ["is invalid"]}},
        {%{"occurred_at" => "yesterday"}, %{"occurred_at" => ["is invalid"]}}
      ]

      for {change, errors} <- bad do
        assert %{"error" => "invalid", "errors" => ^errors} =
                 service(
                   :post,
                   @create,
                   "social",
                   Map.merge(attrs("message_received", me), change)
                 )
                 |> json_response(422)
      end

      # texts: too long, control characters, bidi override; badge without actor only
      for title <- [
            String.duplicate("a", 141),
            "line\nbreak",
            "evil" <> <<0x202E::utf8>> <> "txt"
          ] do
        params = %{"slug" => "a-b", "title" => title}

        assert %{"errors" => %{"params" => ["has an invalid title"]}} =
                 service(
                   :post,
                   @create,
                   "community",
                   attrs("community_reply", me, %{"params" => params})
                 )
                 |> json_response(422)
      end

      assert %{"errors" => %{"actor_id" => ["must be empty for this kind"]}} =
               service(
                 :post,
                 @create,
                 "learning",
                 attrs("badge_earned", me, %{"actor_id" => uuid()})
               )
               |> json_response(422)

      assert Repo.aggregate(Notification, :count) == 0
    end

    test "no service token → 401" do
      conn = build_conn() |> post(@create, attrs("badge_earned", uuid()))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end

  describe "aggregation and idempotence" do
    test "a retried occurrence never counts twice" do
      me = uuid()
      body = attrs("message_received", me, %{"event_id" => "message:m1"})

      assert %{"status" => "created", "id" => id, "count" => 1} =
               service(:post, @create, "social", body) |> json_response(201)

      assert %{"status" => "duplicate", "id" => nil} =
               service(:post, @create, "social", body) |> json_response(200)

      assert %Notification{count: 1} = Repo.get!(Notification, id)
    end

    test "same key and unread: count + 1, back to the top, latest actor; once read: a new unread one" do
      me = uuid()
      conversation = uuid()
      t0 = ~U[2026-11-20 10:00:00.000000Z]

      first =
        create!(
          attrs("message_received", me, %{"conversation_id" => conversation, "event_id" => "m1"}),
          t0
        )

      other = create!(attrs("badge_earned", me), DateTime.add(t0, 60))
      hugo = uuid()

      second =
        create!(
          attrs("message_received", me, %{
            "conversation_id" => conversation,
            "event_id" => "m2",
            "actor_id" => hugo,
            "occurred_at" => "2026-11-20T10:05:00Z"
          }),
          DateTime.add(t0, 300)
        )

      assert second.status == "aggregated"
      assert second.notification.id == first.notification.id

      assert %Notification{count: 2, actor_id: ^hugo} =
               n = Repo.get!(Notification, first.notification.id)

      assert n.last_event_at == ~U[2026-11-20 10:05:00.000000Z]

      # the aggregated conversation is above the badge again
      assert %{"entries" => [%{"id" => top}, %{"id" => below}]} =
               api(:get, "/api/me/notifications", me) |> json_response(200)

      assert {top, below} == {first.notification.id, other.notification.id}

      Repo.update_all(Notification, set: [read_at: DateTime.utc_now()])

      third =
        create!(
          attrs("message_received", me, %{"conversation_id" => conversation, "event_id" => "m3"})
        )

      assert third.status == "created"
      refute third.notification.id == first.notification.id
      assert Repo.aggregate(where(Notification, user_id: ^me), :count) == 3
    end

    test "an event is broadcast to the recipient with a toast (nil when nothing new)" do
      me = uuid()
      MlShared.Events.subscribe("user:#{me}")
      %{notification: n} = create!(attrs("friend_request_received", me))
      assert_receive {:notifications_changed, ^me, %{"id" => id, "category" => "friends"}}
      assert id == n.id

      assert {:ok, _} = MlNotifications.Inbox.read(me, n.id)
      assert_receive {:notifications_changed, ^me, nil}
    end
  end

  describe "read by key (social: conversation read)" do
    test "marks the unread notification of the key, only in the caller's categories" do
      me = uuid()
      conversation = uuid()
      key = "conversation:#{conversation}"

      %{notification: n} =
        create!(attrs("message_received", me, %{"conversation_id" => conversation}))

      assert %{"error" => "forbidden"} =
               service(:post, "/api/internal/notifications/read", "web", %{
                 "user_id" => me,
                 "dedupe_key" => key
               })
               |> json_response(403)

      assert %{"read" => 0} =
               service(:post, "/api/internal/notifications/read", "community", %{
                 "user_id" => me,
                 "dedupe_key" => key
               })
               |> json_response(200)

      assert %{"read" => 1} =
               service(:post, "/api/internal/notifications/read", "social", %{
                 "user_id" => me,
                 "dedupe_key" => key
               })
               |> json_response(200)

      assert Repo.get!(Notification, n.id).read_at
    end

    test "a creation arriving AFTER the read of a later moment is skipped; a newer message notifies" do
      me = uuid()
      conversation = uuid()
      key = "conversation:#{conversation}"

      # social read the conversation at 10:00 before the center received the 09:59 message
      {:ok, 0} =
        MlNotifications.Inbox.read_by_key("social", %{
          "user_id" => me,
          "dedupe_key" => key,
          "read_at" => "2026-11-20T10:00:00Z"
        })

      late =
        attrs("message_received", me, %{
          "conversation_id" => conversation,
          "occurred_at" => "2026-11-20T09:59:00Z",
          "event_id" => "m-late"
        })

      assert %{"status" => "skipped", "id" => nil} =
               service(:post, @create, "social", late) |> json_response(200)

      newer = %{late | "occurred_at" => "2026-11-20T10:01:00Z", "event_id" => "m-new"}

      assert %{"status" => "created"} =
               service(:post, @create, "social", newer) |> json_response(201)
    end

    test "an aggregated notification holding a later event stays unread" do
      me = uuid()
      conversation = uuid()

      create!(
        attrs("message_received", me, %{
          "conversation_id" => conversation,
          "occurred_at" => "2026-11-20T10:05:00Z"
        }),
        ~U[2026-11-20 10:05:01Z]
      )

      {:ok, 0} =
        MlNotifications.Inbox.read_by_key(
          "social",
          %{
            "user_id" => me,
            "dedupe_key" => "conversation:#{conversation}",
            "read_at" => "2026-11-20T10:00:00Z"
          },
          ~U[2026-11-20 10:06:00Z]
        )

      assert [%Notification{read_at: nil}] = Repo.all(where(Notification, user_id: ^me))
    end
  end

  describe "clear between two members (social, on a block)" do
    test "both directions, pending e-mails too; social only" do
      [a, b, c] = [uuid(), uuid(), uuid()]
      create!(attrs("friend_request_received", a, %{"actor_id" => b}))
      create!(attrs("message_received", b, %{"actor_id" => a}))
      create!(attrs("message_received", a, %{"actor_id" => c}))

      Repo.insert!(%PendingEmail{
        user_id: a,
        actor_id: b,
        category: "messages",
        kind: "message_received",
        dedupe_key: "conversation:x",
        inserted_at: DateTime.utc_now()
      })

      assert %{"error" => "forbidden"} =
               service(:post, "/api/internal/notifications/clear-between", "community", %{
                 "a" => a,
                 "b" => b
               })
               |> json_response(403)

      assert %{"deleted" => 2} =
               service(:post, "/api/internal/notifications/clear-between", "social", %{
                 "a" => b,
                 "b" => a
               })
               |> json_response(200)

      assert [%Notification{actor_id: ^c}] = Repo.all(Notification)
      assert Repo.aggregate(PendingEmail, :count) == 0

      assert %{"errors" => %{"a" => ["is invalid"]}} =
               service(:post, "/api/internal/notifications/clear-between", "social", %{
                 "a" => "x",
                 "b" => a
               })
               |> json_response(422)
    end
  end
end
