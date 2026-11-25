defmodule MysticWeb.FriendsLiveTest do
  use MysticWeb.ConnCase, async: true

  setup do
    user = user_fixture()
    hugo = member_fixture()
    ines = member_fixture(%{"username" => "ines_petit", "display_name" => "Inès Petit"})
    sarah = member_fixture(%{"username" => "sarah_lefevre", "display_name" => "Sarah Lefèvre"})
    theo = member_fixture(%{"username" => "theo_garnier", "display_name" => "Théo Garnier"})

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/friends"} => %{"friends" => [hugo]},
        {"GET", "/api/me/friend-requests"} => %{
          "incoming" => [%{"id" => "r1", "from" => ines}],
          "outgoing" => [%{"id" => "r2", "to" => sarah}]
        },
        {"GET", "/api/me/blocks"} => %{"blocks" => [theo]}
      })

    %{user: user, hugo: hugo, ines: ines, theo: theo, routes: routes}
  end

  defp start(conn, routes) do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(~p"/friends")
    view
  end

  test "lists friends, requests and blocked members", %{
    conn: conn,
    routes: routes,
    hugo: hugo,
    ines: ines,
    theo: theo
  } do
    view = start(conn, routes)

    assert has_element?(view, "#friend-#{hugo["id"]}", "Hugo Bernard")
    assert has_element?(view, "#incoming-r1", "Inès Petit")
    assert has_element?(view, "#outgoing-r2", "Sarah Lefèvre")
    assert has_element?(view, "#blocked-#{theo["id"]}", "Théo Garnier")
    assert has_element?(view, "#friend-#{hugo["id"]} a[href='/members/hugo_bernard']")
    refute has_element?(view, "#friend-#{ines["id"]}")
  end

  test "search members and send a friend request", %{conn: conn, routes: routes} do
    clara = member_fixture(%{"username" => "clara_dubois", "display_name" => "Clara Dubois"})

    view =
      start(
        conn,
        Map.merge(routes, %{
          {"GET", "/api/users/search"} => %{"users" => [clara]},
          {"POST", "/api/friend-requests"} => {201, %{"id" => "r3", "status" => "pending"}}
        })
      )

    view |> form("#member-search", %{q: "a"}) |> render_change()
    refute_received {:api, %{path: "/api/users/search"}}

    view |> form("#member-search", %{q: "clara"}) |> render_change()
    assert_received {:api, %{path: "/api/users/search", query: %{"q" => "clara"}}}

    view |> element("#result-#{clara["id"]} button", "Add friend") |> render_click()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/friend-requests",
                       body: %{"user_id" => user_id}
                     }}

    assert user_id == clara["id"]
    assert render(view) =~ "Friend request sent."
  end

  test "accept, decline, cancel, remove, block and unblock call social", %{
    conn: conn,
    routes: routes,
    hugo: hugo,
    theo: theo
  } do
    view =
      start(
        conn,
        Map.merge(routes, %{
          {"POST", "/api/friend-requests/r1/accept"} => %{"id" => "r1", "status" => "accepted"},
          {"POST", "/api/friend-requests/r2/decline"} => {204, nil},
          {"DELETE", "/api/friends/#{hugo["id"]}"} => {204, nil},
          {"POST", "/api/blocks"} => {204, nil},
          {"DELETE", "/api/blocks/#{theo["id"]}"} => {204, nil}
        })
      )

    view |> element("#incoming-r1 button", "Accept") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/friend-requests/r1/accept"}}

    view |> element("#outgoing-r2 button", "Cancel request") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/friend-requests/r2/decline"}}

    view |> element("#friend-#{hugo["id"]} button", "Remove friend") |> render_click()
    assert_received {:api, %{method: "DELETE", path: "/api/friends/" <> _}}

    view |> element("#friend-#{hugo["id"]} button", "Block") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/blocks", body: %{"user_id" => _}}}

    view |> element("#blocked-#{theo["id"]} button", "Unblock") |> render_click()
    assert_received {:api, %{method: "DELETE", path: "/api/blocks/" <> _}}
    assert render(view) =~ "Member unblocked."
  end

  test "a stale request gets a clear message", %{conn: conn, routes: routes} do
    view =
      start(
        conn,
        Map.put(
          routes,
          {"POST", "/api/friend-requests/r1/decline"},
          {404, %{"error" => "not_found"}}
        )
      )

    view |> element("#incoming-r1 button", "Decline") |> render_click()
    assert render(view) =~ "This request is no longer pending."
  end

  test "message a friend opens the conversation", %{conn: conn, routes: routes, hugo: hugo} do
    view =
      start(
        conn,
        Map.put(routes, {"POST", "/api/conversations"}, %{
          "conversation" => %{
            "id" => "c1",
            "other" => hugo,
            "last_message" => nil,
            "unread" => 0
          }
        })
      )

    view |> element("#friend-#{hugo["id"]} button", "Message") |> render_click()
    assert_redirect(view, ~p"/messages/c1")
  end

  test "report a member", %{conn: conn, routes: routes, hugo: hugo} do
    view = start(conn, Map.put(routes, {"POST", "/api/reports"}, {201, %{"id" => "rep1"}}))

    view |> element("#friend-#{hugo["id"]} button", "Report") |> render_click()
    assert has_element?(view, "#report-panel", "Report Hugo Bernard")

    view
    |> form("#report-form", report: %{reason: "spam", details: "Sends links"})
    |> render_submit()

    assert_received {:api, %{method: "POST", path: "/api/reports", body: body}}

    assert body == %{
             "target_type" => "user",
             "target_id" => hugo["id"],
             "reason" => "spam",
             "details" => "Sends links"
           }

    refute has_element?(view, "#report-panel")
    assert render(view) =~ "Report sent."
  end

  test "lists refresh in real time on friendship_changed", %{
    conn: conn,
    routes: routes,
    user: user
  } do
    view = start(conn, routes)
    newcomer = member_fixture(%{"username" => "nova_star", "display_name" => "Nova Star"})

    stub_api(%{routes | {"GET", "/api/me/friends"} => %{"friends" => [newcomer]}})
    MlShared.Events.broadcast("user:#{user["id"]}", {:friendship_changed, user["id"]})

    assert render(view) =~ "Nova Star"
    assert has_element?(view, "#friend-#{newcomer["id"]}")
  end

  test "social unreachable", %{conn: conn, user: user} do
    view =
      start(conn, Map.merge(member_routes(user), %{{"GET", "/api/me/friends"} => :unavailable}))

    assert has_element?(view, "#friends-unavailable")
    assert has_element?(view, "#member-search")
  end
end
