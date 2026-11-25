defmodule MysticWeb.Security.LoginAndRecoveryTest do
  use MysticWeb.ConnCase, async: true

  @login %{email: "lyra@mysticlore.test", password: "mystic-demo-pass-1"}
  @challenge %{"two_factor_required" => true, "challenge" => "chal-123"}

  # Routes answering with a function report the device headers to the test process.
  defp reporting(response) do
    test = self()

    fn conn, body ->
      send(
        test,
        {:device, get_req_header(conn, "x-client-ua"), get_req_header(conn, "x-client-ip"), body}
      )

      response
    end
  end

  defp with_ua(conn),
    do: put_req_header(conn, "user-agent", "Mozilla/5.0 (Macintosh) Firefox/140.0")

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  describe "login without two-factor authentication" do
    test "sends the browser's user agent and IP to accounts", %{conn: conn} do
      stub_api(%{
        {"POST", "/api/sessions"} =>
          reporting({201, %{"session_token" => "tok-1", "user" => user_fixture()}})
      })

      conn = conn |> with_ua() |> post(~p"/login", user: @login)

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "session_token") == "tok-1"
      assert_received {:device, ["Mozilla/5.0 (Macintosh) Firefox/140.0"], [client_ip], _body}
      assert client_ip == ip(conn)
    end

    test "the login page links to the forgotten password page", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~s(href="/forgot-password")
      assert html =~ "Forgot your password?"
    end
  end

  describe "login with two-factor authentication" do
    setup %{conn: conn} do
      stub_api(%{{"POST", "/api/sessions"} => @challenge})
      %{conn: post(conn, ~p"/login", user: @login)}
    end

    test "keeps the challenge in the cookie session (never in the URL) and asks for a code", %{
      conn: conn
    } do
      assert redirected_to(conn) == ~p"/login/2fa"
      assert get_session(conn, "two_factor_challenge") == "chal-123"
      refute get_session(conn, "session_token")

      html = conn |> get(~p"/login/2fa") |> html_response(200)
      assert html =~ ~s(id="two-factor-form")
      assert html =~ ~s(autocomplete="one-time-code")
      refute html =~ "chal-123"
    end

    test "a valid code (TOTP or recovery) opens the session", %{conn: conn} do
      stub_api(%{
        {"POST", "/api/sessions/2fa"} =>
          reporting({201, %{"session_token" => "tok-2fa", "user" => user_fixture()}})
      })

      conn =
        conn
        |> recycle()
        |> with_ua()
        |> post(~p"/login/2fa", two_factor: %{one_time_password: " 123 456 "})

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "session_token") == "tok-2fa"
      refute get_session(conn, "two_factor_challenge")

      assert_received {:device, ["Mozilla/5.0 (Macintosh) Firefox/140.0"], [_ip],
                       %{"challenge" => "chal-123", "code" => "123 456"}}
    end

    test "a wrong code says how many attempts are left", %{conn: conn} do
      stub_api(%{
        {"POST", "/api/sessions/2fa"} => {401, %{"error" => "invalid_code", "attempts_left" => 3}}
      })

      conn = post(conn, ~p"/login/2fa", two_factor: %{one_time_password: "000000"})
      assert html_response(conn, 401) =~ "This code is not valid. 3 attempts left."
      assert get_session(conn, "two_factor_challenge") == "chal-123"
    end

    for {name, response, message} <- [
          {"the last attempt failed", {401, %{"error" => "invalid_code", "attempts_left" => 0}},
           "Too many incorrect codes"},
          {"the challenge expired", {404, %{"error" => "not_found"}}, "has expired"},
          {"the account is locked", {429, %{"error" => "locked"}}, "15 minutes"}
        ] do
      test "back to /login when #{name}", %{conn: conn} do
        stub_api(%{{"POST", "/api/sessions/2fa"} => unquote(Macro.escape(response))})
        conn = post(conn, ~p"/login/2fa", two_factor: %{one_time_password: "000000"})

        assert redirected_to(conn) == ~p"/login"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ unquote(message)
        refute get_session(conn, "two_factor_challenge")
      end
    end

    test "accounts unreachable", %{conn: conn} do
      stub_api(%{{"POST", "/api/sessions/2fa"} => :unavailable})

      assert conn
             |> post(~p"/login/2fa", two_factor: %{one_time_password: "123456"})
             |> html_response(503) =~
               "temporarily unavailable"
    end

    test "is rate limited per IP before reaching accounts", %{conn: conn} do
      stub_api(%{
        {"POST", "/api/sessions/2fa"} => {401, %{"error" => "invalid_code", "attempts_left" => 4}}
      })

      for _ <- 1..10, do: post(conn, ~p"/login/2fa", two_factor: %{one_time_password: "000000"})
      for _ <- 1..10, do: assert_received({:api, %{path: "/api/sessions/2fa"}})

      assert conn
             |> post(~p"/login/2fa", two_factor: %{one_time_password: "000000"})
             |> html_response(429) =~
               "Too many attempts"

      refute_received {:api, %{path: "/api/sessions/2fa"}}
    end
  end

  test "without a pending challenge, the second step sends back to /login", %{conn: conn} do
    assert conn |> get(~p"/login/2fa") |> redirected_to() == ~p"/login"

    assert conn |> post(~p"/login/2fa", two_factor: %{one_time_password: "1"}) |> redirected_to() ==
             ~p"/login"

    refute_received {:api, _}
  end

  describe "forgotten password" do
    test "always the same neutral answer", %{conn: conn} do
      assert conn |> get(~p"/forgot-password") |> html_response(200) =~ ~s(id="forgot-form")
      stub_api(%{{"POST", "/api/password-resets"} => {204, nil}})

      html =
        conn
        |> post(~p"/forgot-password", reset: %{email: "  who@mysticlore.test "})
        |> html_response(200)

      assert html =~ "If an account exists for who@mysticlore.test"

      assert_received {:api,
                       %{path: "/api/password-resets", body: %{"email" => "who@mysticlore.test"}}}
    end

    test "is rate limited per IP", %{conn: conn} do
      stub_api(%{{"POST", "/api/password-resets"} => {204, nil}})
      for _ <- 1..5, do: post(conn, ~p"/forgot-password", reset: %{email: "a@b.test"})
      for _ <- 1..5, do: assert_received({:api, %{path: "/api/password-resets"}})

      assert conn |> post(~p"/forgot-password", reset: %{email: "a@b.test"}) |> html_response(429) =~
               "Too many requests"

      refute_received {:api, _}
    end

    test "accounts unreachable", %{conn: conn} do
      stub_api(%{{"POST", "/api/password-resets"} => :unavailable})

      assert conn |> post(~p"/forgot-password", reset: %{email: "a@b.test"}) |> html_response(503) =~
               "temporarily unavailable"
    end
  end

  describe "reset link" do
    test "GET only checks the link, then the form sets the new password", %{conn: conn} do
      stub_api(%{
        {"GET", "/api/password-resets/tok-ok"} => {204, nil},
        {"POST", "/api/password-resets/tok-ok"} => {204, nil}
      })

      html = conn |> get(~p"/reset-password/tok-ok") |> html_response(200)
      assert html =~ ~s(id="reset-form")
      refute_received {:api, %{method: "POST"}}

      conn = post(conn, ~p"/reset-password/tok-ok", reset: %{password: "a-brand-new-password"})
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "all your sessions signed out"

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/password-resets/tok-ok",
                         body: %{"password" => "a-brand-new-password"}
                       }}
    end

    test "an invalid, expired or used link offers a new one", %{conn: conn} do
      stub_api(%{
        {"GET", "/api/password-resets/old"} => {404, %{"error" => "not_found"}},
        {"POST", "/api/password-resets/old"} => {404, %{"error" => "not_found"}}
      })

      for conn <- [
            get(conn, ~p"/reset-password/old"),
            post(conn, ~p"/reset-password/old", reset: %{password: "x"})
          ] do
        html = html_response(conn, 404)
        assert html =~ ~s(id="reset-invalid")
        assert html =~ ~s(href="/forgot-password")
      end
    end

    test "shows the password rules of accounts, never echoing the password", %{conn: conn} do
      errors = %{"password" => ["should be at least 12 character(s)"]}

      stub_api(%{
        {"POST", "/api/password-resets/tok"} => {422, %{"error" => "invalid", "errors" => errors}}
      })

      html =
        conn
        |> post(~p"/reset-password/tok", reset: %{password: "short-pw"})
        |> html_response(422)

      assert html =~ "should be at least 12 characters"
      refute html =~ "short-pw"
    end

    test "the token can't reach another accounts route", %{conn: conn} do
      stub_api(%{})
      get(conn, "/reset-password/..%2Fsessions%2Fcurrent")
      assert_received {:api, %{path: path}}
      assert path == "/api/password-resets/..%2Fsessions%2Fcurrent"
    end
  end
end
