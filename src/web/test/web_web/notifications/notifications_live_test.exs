defmodule MysticWeb.NotificationsLiveTest do
  @moduledoc """
  `/notifications`: texts written here from `kind` + `params`, links computed here, cursor pages, read one / all,
  live updates, honest « unavailable » state.
  """
  use MysticWeb.ConnCase, async: true

  @orion %{
    "id" => "00000000-0000-4000-8000-000000000002",
    "username" => "hugo_bernard",
    "display_name" => "Hugo Bernard",
    "avatar" => nil
  }

  defp notification(attrs) do
    Map.merge(
      %{
        "id" => uuid(),
        "category" => "messages",
        "kind" => "message_received",
        "actor_id" => @orion["id"],
        "actor" => @orion,
        "subject" => nil,
        "params" => %{"conversation_id" => uuid(), "conversation_kind" => "direct"},
        "count" => 1,
        "read" => false,
        "read_at" => nil,
        "created_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -120)),
        "updated_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -120))
      },
      attrs
    )
  end

  defp list_page(entries, attrs \\ %{}),
    do:
      Map.merge(%{"entries" => entries, "next_before" => nil, "unread" => length(entries)}, attrs)

  defp open(conn, user, routes) do
    stub_api(Map.merge(member_routes(user), routes))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/notifications")
    view
  end

  setup do
    {:ok, user: user_fixture()}
  end

  test "newest first: localized text, actor, relative time, unread marked, category, link to open",
       %{
         conn: conn,
         user: user
       } do
    message = notification(%{"count" => 3})

    badge =
      notification(%{
        "category" => "learning",
        "kind" => "badge_earned",
        "actor_id" => nil,
        "actor" => nil,
        "params" => %{"badge_slug" => "first-spark", "badge_name" => "Première étincelle"},
        "read" => true,
        "updated_at" => "2026-11-01T09:00:00Z"
      })

    view = open(conn, user, %{{"GET", "/api/me/notifications"} => list_page([message, badge])})

    assert has_element?(
             view,
             "#notification-#{message["id"]}.is-unread",
             "Hugo Bernard sent you 3 messages"
           )

    assert has_element?(view, "#notification-#{message["id"]}", "2 min ago")
    assert has_element?(view, "#notification-#{message["id"]} .sr-only", "Unread.")
    assert has_element?(view, "#notification-#{message["id"]}", "Messages")

    assert has_element?(
             view,
             "#open-#{message["id"]}[href='/notifications?open=#{message["id"]}']"
           )

    assert has_element?(view, "#read-#{message["id"]}[aria-label='Mark as read']")

    refute has_element?(view, "#notification-#{badge["id"]}.is-unread")

    assert has_element?(
             view,
             "#notification-#{badge["id"]}",
             "You earned the badge “Première étincelle”"
           )

    assert has_element?(view, "#notification-#{badge["id"]}", "Nov 1 · ")
    refute has_element?(view, "#read-#{badge["id"]}")

    # the bell itself shows no toast on this page, and the filters are links kept in the URL
    assert has_element?(view, "#filter-all[aria-current='page']")
    assert has_element?(view, "#filter-unread[href='/notifications?filter=unread']")
  end

  test "unread filter, empty state", %{conn: conn, user: user} do
    view = open(conn, user, %{{"GET", "/api/me/notifications"} => list_page([])})
    assert has_element?(view, "#notifications-empty", "No notifications yet")
    refute has_element?(view, "#read-all")

    view |> element("#filter-unread") |> render_click()
    assert_patch(view, ~p"/notifications?filter=unread")
    assert_received {:api, %{path: "/api/me/notifications", query: %{"filter" => "unread"}}}
    assert has_element?(view, "#filter-unread[aria-current='page']")
    assert has_element?(view, "#notifications-empty", "Nothing unread")
  end

  test "the center unreachable: an honest unavailable state, no made-up data", %{
    conn: conn,
    user: user
  } do
    view = open(conn, user, %{{"GET", "/api/me/notifications"} => :unavailable})
    assert has_element?(view, "#notifications-unavailable", "can't be loaded right now")
    refute has_element?(view, "#notification-list")
    refute has_element?(view, "#notifications-empty")
    refute has_element?(view, "#read-all")
  end

  test "read one, then all (the list reloads after the center answered)", %{
    conn: conn,
    user: user
  } do
    n = notification(%{})

    view =
      open(conn, user, %{
        {"GET", "/api/me/notifications"} => list_page([n]),
        {"POST", "/api/me/notifications/#{n["id"]}/read"} => %{
          "notification" => %{n | "read" => true}
        },
        {"POST", "/api/me/notifications/read-all"} => %{"read" => 1, "unread" => 0}
      })

    view |> element("#read-#{n["id"]}") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/me/notifications/" <> _}}

    view |> element("#read-all") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/me/notifications/read-all"}}
    assert render(view) =~ "All your notifications are read."
  end

  test "load more by cursor", %{conn: conn, user: user} do
    first = notification(%{})

    older =
      notification(%{
        "kind" => "friend_request_received",
        "category" => "friends",
        "params" => %{}
      })

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/notifications"} => fn conn, _ ->
          case URI.decode_query(conn.query_string) do
            %{"before" => "cursor-2"} -> {200, list_page([older], %{"unread" => 2})}
            _ -> {200, list_page([first], %{"next_before" => "cursor-2", "unread" => 2})}
          end
        end
      })
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/notifications")
    refute has_element?(view, "#notification-#{older["id"]}")
    view |> element("#load-more") |> render_click()
    assert has_element?(view, "#notification-#{first["id"]}")

    assert has_element?(
             view,
             "#notification-#{older["id"]}",
             "Hugo Bernard sent you a friend request"
           )

    refute has_element?(view, "#load-more")
  end

  test "opening a notification marks it read, then goes to its computed target", %{
    conn: conn,
    user: user
  } do
    conversation = uuid()

    n =
      notification(%{
        "params" => %{"conversation_id" => conversation, "conversation_kind" => "direct"}
      })

    request =
      notification(%{
        "kind" => "friend_request_received",
        "category" => "friends",
        "params" => %{}
      })

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/notifications"} => list_page([n, request]),
        {"POST", "/api/me/notifications/#{n["id"]}/read"} => %{
          "notification" => %{n | "read" => true}
        },
        {"POST", "/api/me/notifications/#{request["id"]}/read"} => %{"notification" => request}
      })
    )

    conn = log_in(conn)
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/notifications?open=#{n["id"]}")
    assert to == "/messages/#{conversation}"

    assert {:error, {:live_redirect, %{to: "/friends"}}} =
             live(conn, ~p"/notifications?open=#{request["id"]}")

    # unknown (or someone else's: the center answers 404) → back to the list, with a message
    assert {:error, {:live_redirect, %{to: "/notifications", flash: flash}}} =
             live(conn, ~p"/notifications?open=#{uuid()}")

    assert flash["error"] == "This notification no longer exists."
  end

  test "links are computed here: unexpected identifiers lead to a general page, never elsewhere" do
    assert MysticWeb.Notifications.path(%{
             "kind" => "message_received",
             "params" => %{"conversation_id" => "//evil.example"}
           }) ==
             "/messages"

    assert MysticWeb.Notifications.path(%{
             "kind" => "community_reply",
             "params" => %{"slug" => "../admin"}
           }) ==
             "/community"

    assert MysticWeb.Notifications.path(%{
             "kind" => "community_reply",
             "params" => %{"slug" => "why-range-ab12"}
           }) ==
             "/community/discussions/why-range-ab12"

    assert MysticWeb.Notifications.path(%{
             "kind" => "lobby_invite",
             "params" => %{"lobby_id" => uuid()}
           }) ==
             "/multiplayer"

    assert MysticWeb.Notifications.path(%{"kind" => "payment_failed", "params" => %{}}) ==
             "/membership"

    assert MysticWeb.Notifications.path(%{"kind" => "two_factor_disabled"}) ==
             "/settings/security"

    assert MysticWeb.Notifications.path(%{"kind" => "export_ready", "params" => %{}}) ==
             "/settings/data"

    assert MysticWeb.Notifications.path(%{"kind" => "from_the_future", "params" => %{}}) ==
             "/notifications"
  end

  test "studio decisions: title and reviewer's reason read at studio for this member (never stored)",
       %{
         conn: conn,
         user: user
       } do
    project = uuid()

    n =
      notification(%{
        "category" => "studio",
        "kind" => "review_rejected",
        "actor_id" => nil,
        "actor" => nil,
        "params" => %{"project_id" => project}
      })

    view =
      open(conn, user, %{
        {"GET", "/api/me/notifications"} => list_page([n]),
        {"GET", "/api/projects/#{project}"} => %{
          "project" => %{
            "id" => project,
            "title" => "Le Jardin au clair de lune",
            "review" => %{"decision" => "rejected", "reason" => "Please add image descriptions."}
          }
        }
      })

    assert has_element?(
             view,
             "#notification-#{n["id"]}",
             "Your studio project “Le Jardin au clair de lune” was sent back to draft"
           )

    assert has_element?(
             view,
             "#notification-#{n["id"]} .notification-detail",
             "Please add image descriptions."
           )
  end

  test "live: a change of the list reloads it (no polling)", %{conn: conn, user: user} do
    n = notification(%{})
    view = open(conn, user, %{{"GET", "/api/me/notifications"} => list_page([])})
    assert has_element?(view, "#notifications-empty")

    stub_api(
      Map.merge(member_routes(user), %{{"GET", "/api/me/notifications"} => list_page([n])})
    )

    MlShared.Events.broadcast("user:#{user["id"]}", {:notifications_changed, user["id"], nil})

    assert has_element?(view, "#notification-#{n["id"]}", "Hugo Bernard sent you a message")
    # no toast on this page, even for a new notification
    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:notifications_changed, user["id"], %{"id" => n["id"], "category" => "messages"}}
    )

    refute has_element?(view, "#notification-toast")
  end

  test "localized texts for every category (en)" do
    texts = [
      {%{
         "kind" => "message_received",
         "params" => %{"conversation_kind" => "group", "group_name" => "Night owls"}
       }, "Hugo Bernard wrote in “Night owls”"},
      {%{"kind" => "group_added", "params" => %{"group_name" => "Night owls"}},
       "Hugo Bernard added you to the group “Night owls”"},
      {%{"kind" => "friend_request_accepted"}, "Hugo Bernard accepted your friend request"},
      {%{"kind" => "community_reply", "count" => 2, "params" => %{"title" => "Loops"}},
       "2 new replies in “Loops”"},
      {%{"kind" => "lobby_invite", "params" => %{"lobby_title" => "Rune night"}},
       "Hugo Bernard invited you to the activity “Rune night”"},
      {%{"kind" => "subscription_activated", "params" => %{"plan" => "vip"}},
       "Your VIP membership is active"},
      {%{"kind" => "subscription_ended", "params" => %{"plan" => "premium"}},
       "Your Premium membership has ended"},
      {%{"kind" => "password_changed", "params" => %{"method" => "reset"}},
       "Your password was reset"},
      {%{"kind" => "sessions_revoked", "params" => %{"count" => 2}},
       "2 sessions of your account were signed out"},
      {%{"kind" => "appeal_decided", "params" => %{"outcome" => "accepted"}},
       "Your appeal was accepted"},
      {%{"kind" => "export_ready"}, "Your data export is ready to download"},
      {%{"kind" => "message_received", "actor" => nil}, "A member sent you a message"}
    ]

    for {attrs, expected} <- texts do
      n = Map.merge(%{"actor" => @orion, "count" => 1, "params" => %{}}, attrs)
      assert MysticWeb.Notifications.text(n) =~ expected
    end
  end
end
