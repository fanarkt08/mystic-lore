defmodule MysticWeb.AccessTest do
  use MysticWeb.ConnCase, async: true

  @member_pages ~w(/dashboard /learn/la-foret-des-murmures/l1 /membership /membership/local-checkout/cs_1
                   /membership/success /membership/cancel /friends /messages /messages/c1
                   /settings /settings/security)

  for path <- @member_pages do
    test "#{path} redirects to /login when signed out, to come back afterwards", %{conn: conn} do
      assert {:error, {:redirect, %{to: to, flash: %{"error" => _}}}} =
               live(conn, unquote(path))

      assert to == "/login?" <> URI.encode_query(return_to: unquote(path))
    end
  end

  test "an expired or revoked session token: the login page explains it, then brings the member back",
       %{conn: conn} do
    stub_api(%{{"GET", "/api/sessions/current"} => {401, %{"error" => "unauthorized"}}})

    assert {:error, {:redirect, %{to: "/login?reason=expired&return_to=%2Fdashboard"} = redirect}} =
             conn |> log_in() |> live(~p"/dashboard")

    # one explanation (the page), no flash on top of it
    refute redirect[:flash]["error"]
  end

  test "the page asked for keeps its query string; a foreign or guest page is never a destination" do
    assert MysticWeb.Auth.login_path("/adventures?page=2") ==
             "/login?return_to=%2Fadventures%3Fpage%3D2"

    for bad <- [
          "https://evil.example/x",
          "//evil.example",
          "/\\evil",
          "/login",
          "/register",
          "/",
          nil
        ] do
      assert MysticWeb.Auth.login_path(bad) == "/login"
    end
  end

  test "accounts unreachable: explained redirection instead of a crash", %{conn: conn} do
    stub_api(%{{"GET", "/api/sessions/current"} => :unavailable})

    assert {:error,
            {:redirect, %{to: "/login?return_to=%2Fdashboard", flash: %{"error" => message}}}} =
             conn |> log_in() |> live(~p"/dashboard")

    assert message =~ "can't verify your session"
  end

  test "the session token travels in x-session-token, next to the internal token", %{conn: conn} do
    test = self()
    user = user_fixture()

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/sessions/current"} => fn conn, _ ->
          send(
            test,
            {:token, get_req_header(conn, "x-session-token"),
             get_req_header(conn, "authorization")}
          )

          %{"user" => user}
        end
      })
    )

    {:ok, _view, _html} = conn |> log_in("tok-42") |> live(~p"/settings")
    assert_received {:token, ["tok-42"], ["Bearer " <> _]}
  end
end
