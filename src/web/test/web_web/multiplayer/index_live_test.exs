defmodule MysticWeb.Multiplayer.IndexLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.MultiplayerFixtures

  setup do
    user = user_fixture()
    hugo = player(uuid(), "Hugo Bernard")
    open_lobby = lobby_summary(%{"id" => "open-1", "starts_at" => "2026-11-24T18:00:00Z"})
    mine = lobby_summary(%{"id" => "mine-1", "title" => "Relais entre amies", "role" => "host"})

    invite = %{
      "id" => "inv-1",
      "inviter" => hugo,
      "lobby" =>
        lobby_summary(%{"id" => "priv-1", "title" => "Secret Relay", "visibility" => "private"}),
      "inserted_at" => "2026-11-23T10:00:00Z"
    }

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/lobbies"} => page([open_lobby]),
        {"GET", "/api/me/lobbies"} => %{"lobbies" => [mine]},
        {"GET", "/api/me/invites"} => %{"invites" => [invite]}
      })

    %{user: user, routes: routes}
  end

  defp open(conn, routes) do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(~p"/multiplayer")
    view
  end

  test "signed out: redirected to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login?return_to=%2Fmultiplayer"}}} =
             live(conn, ~p"/multiplayer")
  end

  test "lists open activities (UTC start time), my activities and my invitations", %{
    conn: conn,
    routes: routes
  } do
    view = open(conn, routes)
    assert has_element?(view, "#open-open-1", "Relais du soir")
    assert has_element?(view, "#open-open-1", "Starts Nov 24, 2026 · 18:00 UTC")
    assert has_element?(view, "#open-open-1", "2 of 4 players")
    assert has_element?(view, "#mine-mine-1", "You are the host")
    assert has_element?(view, "#invite-inv-1", "Secret Relay")
    assert has_element?(view, "#invite-inv-1", "Invited by Hugo Bernard")
  end

  test "creates an activity (start time read as UTC) and opens it", %{conn: conn, routes: routes} do
    routes = Map.put(routes, {"POST", "/api/lobbies"}, {201, %{"lobby" => %{"id" => "new-1"}}})
    view = open(conn, routes)

    params = %{
      title: "  Dawn Relay ",
      max_players: "3",
      visibility: "private",
      requires_approval: "true",
      starts_at: "2026-11-30T18:30"
    }

    assert {:error, {:live_redirect, %{to: "/multiplayer/lobbies/new-1"}}} =
             view |> form("#create-lobby", lobby: params) |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/lobbies",
                       body: %{
                         "title" => "Dawn Relay",
                         "max_players" => 3,
                         "visibility" => "private",
                         "requires_approval" => true,
                         "starts_at" => "2026-11-30T18:30:00Z"
                       }
                     }}
  end

  test "creation errors: service validation and host limit are shown", %{
    conn: conn,
    routes: routes
  } do
    invalid =
      {422, %{"error" => "invalid", "errors" => %{"starts_at" => ["must be in the future"]}}}

    view = open(conn, Map.put(routes, {"POST", "/api/lobbies"}, invalid))

    view
    |> form("#create-lobby", lobby: %{title: "Old", starts_at: "2020-01-01T10:00"})
    |> render_submit()

    assert has_element?(view, "#create-lobby", "must be in the future")

    stub_api(Map.put(routes, {"POST", "/api/lobbies"}, {409, %{"error" => "too_many_lobbies"}}))
    view |> form("#create-lobby", lobby: %{title: "Fourth"}) |> render_submit()
    assert render(view) =~ "You already host 3 activities"
  end

  test "a new invitation arrives in real time (user:<id>)", %{
    conn: conn,
    routes: routes,
    user: user
  } do
    view = open(conn, Map.put(routes, {"GET", "/api/me/invites"}, %{"invites" => []}))
    refute has_element?(view, "#invite-inv-1")

    stub_api(routes)

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:lobby_invite,
       %{
         "id" => "inv-1",
         "lobby_id" => "priv-1",
         "lobby_title" => "Secret Relay",
         "inviter_id" => "x"
       }}
    )

    assert has_element?(view, "#invite-inv-1", "Secret Relay")

    # the announcement is the notification center's toast (one per invitation), not a flash of this page
    refute render(view) =~ "New invitation to"
  end

  test "accepting an invitation opens the lobby; declining reloads the list", %{
    conn: conn,
    routes: routes
  } do
    routes =
      Map.merge(routes, %{
        {"POST", "/api/invites/inv-1/accept"} => %{"lobby_id" => "priv-1"},
        {"POST", "/api/invites/inv-1/decline"} => {204, nil}
      })

    view = open(conn, routes)
    view |> element("#decline-inv-1") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/invites/inv-1/decline"}}

    assert {:error, {:live_redirect, %{to: "/multiplayer/lobbies/priv-1"}}} =
             view |> element("#accept-inv-1") |> render_click()
  end

  test "multiplayer unavailable: each zone says so, the page stays usable", %{
    conn: conn,
    user: user
  } do
    view =
      open(
        conn,
        Map.merge(member_routes(user), %{
          {"GET", "/api/lobbies"} => :unavailable,
          {"GET", "/api/me/lobbies"} => :unavailable,
          {"GET", "/api/me/invites"} => :unavailable
        })
      )

    assert has_element?(view, "#open-unavailable")
    assert has_element?(view, "#mp-invites", "can't be loaded")
    assert has_element?(view, "#create-lobby")
  end
end
