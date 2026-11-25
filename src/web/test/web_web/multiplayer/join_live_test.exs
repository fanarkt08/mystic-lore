defmodule MysticWeb.Multiplayer.JoinLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.MultiplayerFixtures

  setup do
    user = user_fixture()
    %{routes: member_routes(user)}
  end

  defp open(conn, routes, token \\ "tok-123") do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(~p"/multiplayer/join/#{token}")
    view
  end

  test "valid link: preview, then joining needs a click (token sent in the body)", %{
    conn: conn,
    routes: routes
  } do
    routes =
      Map.merge(routes, %{
        {"POST", "/api/links/preview"} => %{
          "lobby" => lobby_summary(%{"id" => "lobby-9", "title" => "Secret Relay"})
        },
        {"POST", "/api/links/join"} => %{"lobby_id" => "lobby-9"}
      })

    view = open(conn, routes)
    assert has_element?(view, "#invitation", "Join “Secret Relay”")
    assert has_element?(view, "#invitation", "Hugo Bernard invites you")

    assert_received {:api,
                     %{method: "POST", path: "/api/links/preview", body: %{"token" => "tok-123"}}}

    refute_received {:api, %{path: "/api/links/join"}}

    assert {:error, {:live_redirect, %{to: "/multiplayer/lobbies/lobby-9"}}} =
             view |> element("#join-link") |> render_click()

    assert_received {:api,
                     %{method: "POST", path: "/api/links/join", body: %{"token" => "tok-123"}}}
  end

  for {code, text} <- [
        {"expired", "has expired"},
        {"revoked", "was revoked"},
        {"exhausted", "is used up"},
        {"closed", "has ended"}
      ] do
    test "#{code} link: clear explanation, nothing about the activity", %{
      conn: conn,
      routes: routes
    } do
      view =
        open(
          conn,
          Map.put(routes, {"POST", "/api/links/preview"}, {410, %{"error" => unquote(code)}})
        )

      assert has_element?(view, "#link-invalid", unquote(text))
      refute has_element?(view, "#invitation")
      refute has_element?(view, "#join-link")
    end
  end

  test "unknown token: invalid link", %{conn: conn, routes: routes} do
    view =
      open(
        conn,
        Map.put(routes, {"POST", "/api/links/preview"}, {404, %{"error" => "not_found"}}),
        "nope"
      )

    assert has_element?(view, "#link-invalid", "isn't valid")
  end

  test "join refused (full activity, link used up meanwhile)", %{conn: conn, routes: routes} do
    routes =
      Map.merge(routes, %{
        {"POST", "/api/links/preview"} => %{"lobby" => lobby_summary()},
        {"POST", "/api/links/join"} => {409, %{"error" => "full"}}
      })

    view = open(conn, routes)
    view |> element("#join-link") |> render_click()
    # an explicit state with the next step (check again, other activities)
    assert has_element?(view, "#link-invalid", "This activity is full")
    assert has_element?(view, "#link-check-again[href='/multiplayer/join/tok-123']")
    refute has_element?(view, "#join-link")

    view =
      open(conn, Map.put(routes, {"POST", "/api/links/join"}, {410, %{"error" => "exhausted"}}))

    view |> element("#join-link") |> render_click()
    assert has_element?(view, "#link-invalid", "is used up")
  end

  test "service unavailable", %{conn: conn, routes: routes} do
    view = open(conn, Map.put(routes, {"POST", "/api/links/preview"}, :unavailable))
    assert has_element?(view, "#link-unavailable")
  end
end
