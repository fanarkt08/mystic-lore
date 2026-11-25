defmodule MysticWeb.DashboardLiveTest do
  use MysticWeb.ConnCase, async: true

  defp dashboard do
    today = Date.utc_today()

    %{
      "level" => 3,
      "xp" => 260,
      "into_level" => 60,
      "per_level" => 100,
      "streak" => 4,
      "week" =>
        for(i <- 6..0//-1, do: %{"date" => Date.to_iso8601(Date.add(today, -i)), "xp" => i * 10}),
      "current" => %{
        "slug" => "la-foret-des-murmures",
        "title" => "La Forêt des murmures",
        "percent" => 40,
        "resume_lesson_id" => "l2"
      },
      "recommendations" => [
        adventure(%{"slug" => "celestial-atlas", "title" => "L'Atlas céleste"})
      ]
    }
  end

  defp requests(incoming), do: %{"incoming" => incoming, "outgoing" => []}

  test "shows progress, activity, plan and pending requests", %{conn: conn} do
    user = user_fixture()
    hugo = member_fixture()

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/dashboard"} => dashboard(),
        {"GET", "/api/me/billing"} =>
          billing(user["id"], %{"plan" => "premium", "status" => "active"}),
        {"GET", "/api/me/friend-requests"} => requests([%{"id" => "r1", "from" => hugo}])
      })
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")

    assert has_element?(view, "#resume[href='/learn/la-foret-des-murmures/l2']")
    assert has_element?(view, "#level", "Level 3")
    assert has_element?(view, "#level", "60 / 100 XP to level 4")
    assert has_element?(view, "#streak", "4-day streak")
    assert has_element?(view, "#week-chart table td", "60")
    assert has_element?(view, "#plan", "Premium")
    assert has_element?(view, "#reco-celestial-atlas")
    assert has_element?(view, "#request-r1", "Hugo Bernard")
  end

  test "accepting a request calls social and refreshes the list", %{conn: conn} do
    user = user_fixture()
    hugo = member_fixture()

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/dashboard"} => dashboard(),
        {"GET", "/api/me/billing"} => billing(user["id"]),
        {"GET", "/api/me/friend-requests"} => requests([%{"id" => "r1", "from" => hugo}])
      })

    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")

    stub_api(
      Map.merge(routes, %{
        {"POST", "/api/friend-requests/r1/accept"} => %{"id" => "r1", "status" => "accepted"},
        {"GET", "/api/me/friend-requests"} => requests([])
      })
    )

    view |> element("#request-r1 button", "Accept") |> render_click()

    assert_received {:api, %{method: "POST", path: "/api/friend-requests/r1/accept"}}
    refute has_element?(view, "#request-r1")
    assert render(view) =~ "Friend request accepted."
  end

  test "zones degrade independently and follow real-time friendship events", %{conn: conn} do
    user = user_fixture()

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/dashboard"} => :unavailable,
        {"GET", "/api/me/billing"} => :unavailable,
        {"GET", "/api/me/friend-requests"} => requests([])
      })

    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")

    assert has_element?(view, "#current-adventure", "Temporarily unavailable")
    assert has_element?(view, "#plan", "Temporarily unavailable")
    assert has_element?(view, "#friend-requests", "No pending requests.")

    stub_api(
      Map.merge(routes, %{
        {"GET", "/api/me/friend-requests"} =>
          requests([%{"id" => "r2", "from" => member_fixture()}])
      })
    )

    MlShared.Events.broadcast("user:#{user["id"]}", {:friendship_changed, user["id"]})

    assert render(view) =~ "Hugo Bernard"
    assert has_element?(view, "#request-r2")
  end
end
