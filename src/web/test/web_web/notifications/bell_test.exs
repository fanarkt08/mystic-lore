defmodule MysticWeb.Notifications.BellTest do
  @moduledoc "The notification bell and its toast on every signed-in page."
  use MysticWeb.ConnCase, async: true

  defp count_route(n), do: %{{"GET", "/api/me/notifications/unread-count"} => %{"unread" => n}}

  defp dashboard(conn, user, routes) do
    stub_api(
      member_routes(user)
      |> Map.merge(%{
        {"GET", "/api/me/dashboard"} => :unavailable,
        {"GET", "/api/me/billing"} => :unavailable,
        {"GET", "/api/me/friend-requests"} => :unavailable,
        {"GET", "/api/me/quests"} => :unavailable
      })
      |> Map.merge(routes)
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
    view
  end

  defp toast_routes(id, attrs \\ %{}) do
    notification =
      Map.merge(
        %{
          "id" => id,
          "category" => "friends",
          "kind" => "friend_request_received",
          "actor" => %{
            "id" => uuid(),
            "display_name" => "Sarah Lefèvre",
            "username" => "sarah_lefevre"
          },
          "params" => %{},
          "subject" => %{"type" => "member", "id" => uuid()},
          "count" => 1,
          "read" => false
        },
        attrs
      )

    %{{"GET", "/api/me/notifications/#{id}"} => %{"notification" => notification}}
  end

  test "rail and mobile header: the unread count and an aria-label with the number", %{conn: conn} do
    user = user_fixture()
    view = dashboard(conn, user, count_route(3))

    assert has_element?(
             view,
             "#nav-notifications[href='/notifications'][aria-label='Notifications, 3 unread']"
           )

    assert has_element?(view, "#nav-notifications .count-badge", "3")
    assert has_element?(view, "#mobile-bell.bell-button[aria-label='Notifications, 3 unread']")

    # live: the center changed the list → the count is read again (no polling)
    stub_api(
      member_routes(user)
      |> Map.merge(count_route(4))
      |> Map.merge(%{{"GET", "/api/me/dashboard"} => :unavailable})
    )

    MlShared.Events.broadcast("user:#{user["id"]}", {:notifications_changed, user["id"], nil})
    assert has_element?(view, "#mobile-bell[aria-label='Notifications, 4 unread']")
  end

  test "zero, and the center unreachable: said in the label, no made-up number", %{conn: conn} do
    user = user_fixture()
    view = dashboard(conn, user, count_route(0))
    assert has_element?(view, "#mobile-bell[aria-label='Notifications, none unread']")
    refute has_element?(view, "#mobile-bell .count-badge")

    view = dashboard(conn, user, %{{"GET", "/api/me/notifications/unread-count"} => :unavailable})
    assert has_element?(view, "#mobile-bell[aria-label='Notifications (count unavailable)']")
    refute has_element?(view, "#mobile-bell .count-badge")
  end

  test "a new notification shows a polite toast linking to it; it can be dismissed", %{conn: conn} do
    user = user_fixture()
    id = uuid()
    view = dashboard(conn, user, toast_routes(id))
    assert has_element?(view, "#notification-toasts[aria-live='polite']")
    refute has_element?(view, "#notification-toast")

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:notifications_changed, user["id"], %{"id" => id, "category" => "friends"}}
    )

    assert has_element?(view, "#notification-toast", "Sarah Lefèvre sent you a friend request")
    assert has_element?(view, "#notification-toast-link[href='/notifications?open=#{id}']")

    view |> element("#notification-toast-close") |> render_click()
    refute has_element?(view, "#notification-toast")
  end

  test "the toast goes away by itself", %{conn: conn} do
    user = user_fixture()
    id = uuid()
    view = dashboard(conn, user, toast_routes(id))

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:notifications_changed, user["id"], %{"id" => id, "category" => "friends"}}
    )

    assert has_element?(view, "#notification-toast")
    send(view.pid, {:notification_toast_expired, id})
    refute has_element?(view, "#notification-toast")
  end

  test "quiet hours: the center sends no toast; the count still updates silently", %{conn: conn} do
    user = user_fixture()
    view = dashboard(conn, user, count_route(1))

    stub_api(
      member_routes(user)
      |> Map.merge(count_route(2))
      |> Map.merge(%{{"GET", "/api/me/dashboard"} => :unavailable})
    )

    MlShared.Events.broadcast("user:#{user["id"]}", {:notifications_changed, user["id"], nil})
    assert has_element?(view, "#mobile-bell[aria-label='Notifications, 2 unread']")
    refute has_element?(view, "#notification-toast")

    # no notification was even fetched for a toast
    fetched =
      Stream.repeatedly(fn ->
        receive do
          {:api, %{path: path}} -> path
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert "/api/me/notifications/unread-count" in fetched
    refute Enum.any?(fetched, &(&1 =~ ~r"^/api/me/notifications/[0-9a-f-]{36}$"))
  end

  test "an already read notification is not announced", %{conn: conn} do
    user = user_fixture()
    id = uuid()
    view = dashboard(conn, user, toast_routes(id, %{"read" => true}))

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:notifications_changed, user["id"], %{"id" => id, "category" => "friends"}}
    )

    refute has_element?(view, "#notification-toast")
  end

  test "on /messages, new messages show up live: no toast of that category (others still)", %{
    conn: conn
  } do
    user = user_fixture()
    [message, request] = [uuid(), uuid()]

    stub_api(
      member_routes(user)
      |> Map.merge(%{
        {"GET", "/api/me/conversations"} => %{"conversations" => []},
        {"GET", "/api/me/friends"} => %{"friends" => []}
      })
      |> Map.merge(
        toast_routes(message, %{"category" => "messages", "kind" => "message_received"})
      )
      |> Map.merge(toast_routes(request))
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/messages")

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:notifications_changed, user["id"], %{"id" => message, "category" => "messages"}}
    )

    refute has_element?(view, "#notification-toast")

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:notifications_changed, user["id"], %{"id" => request, "category" => "friends"}}
    )

    assert has_element?(view, "#notification-toast", "Sarah Lefèvre sent you a friend request")
  end

  test "staff pages have the bell too", %{conn: conn} do
    admin = user_fixture(%{"role" => "admin"})

    stub_api(
      member_routes(admin)
      |> Map.merge(count_route(5))
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/admin")
    assert has_element?(view, "#admin-bell[aria-label='Notifications, 5 unread']")
  end
end
