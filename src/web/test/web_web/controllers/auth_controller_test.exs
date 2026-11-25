defmodule MysticWeb.AuthControllerTest do
  # async: false, because one test toggles the :dev_hints application env
  use MysticWeb.ConnCase, async: false

  @login %{email: "lyra@mysticlore.test", password: "mystic-demo-pass-1"}

  describe "login" do
    test "renders the form", %{conn: conn} do
      assert html_response(get(conn, ~p"/login"), 200) =~ ~s(id="login-form")
    end

    test "valid credentials store the session token and open the dashboard", %{conn: conn} do
      stub_api(%{
        {"POST", "/api/sessions"} =>
          {201, %{"session_token" => "tok-1", "user" => user_fixture()}}
      })

      conn = post(conn, ~p"/login", user: @login)

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "session_token") == "tok-1"
      assert get_session(conn, "live_socket_id") =~ "sessions:"

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/sessions",
                         body: %{"email" => "lyra@mysticlore.test"}
                       }}

      [cookie] = get_resp_header(conn, "set-cookie")
      assert cookie =~ "HttpOnly"
      assert cookie =~ "SameSite=Lax"
    end

    test "invalid credentials (401)", %{conn: conn} do
      stub_api(%{{"POST", "/api/sessions"} => {401, %{"error" => "invalid_credentials"}}})
      conn = post(conn, ~p"/login", user: @login)
      assert html_response(conn, 401) =~ "Invalid email or password."
      refute get_session(conn, "session_token")
    end

    test "unconfirmed e-mail (403) offers to resend the confirmation", %{conn: conn} do
      stub_api(%{{"POST", "/api/sessions"} => {403, %{"error" => "unconfirmed"}}})
      html = conn |> post(~p"/login", user: @login) |> html_response(403)
      assert html =~ "Please confirm your email first"
      assert html =~ ~s(id="login-resend")
      assert html =~ ~s(value="lyra@mysticlore.test")
    end

    test "locked account (429)", %{conn: conn} do
      stub_api(%{{"POST", "/api/sessions"} => {429, %{"error" => "locked"}}})
      assert conn |> post(~p"/login", user: @login) |> html_response(429) =~ "15 minutes"
    end

    test "accounts unreachable", %{conn: conn} do
      stub_api(%{{"POST", "/api/sessions"} => :unavailable})

      assert conn |> post(~p"/login", user: @login) |> html_response(503) =~
               "temporarily unavailable"
    end

    test "is rate limited per IP before reaching accounts", %{conn: conn} do
      stub_api(%{{"POST", "/api/sessions"} => {401, %{"error" => "invalid_credentials"}}})
      {limit, _window} = Application.fetch_env!(:web, :rate_limits)[:login]

      for _ <- 1..limit, do: assert(post(conn, ~p"/login", user: @login).status == 401)
      for _ <- 1..limit, do: assert_received({:api, %{path: "/api/sessions"}})

      assert conn |> post(~p"/login", user: @login) |> html_response(429) =~ "Too many attempts"
      refute_received {:api, %{path: "/api/sessions"}}
    end

    test "signed-in members are sent to their dashboard", %{conn: conn} do
      stub_api(%{{"GET", "/api/sessions/current"} => %{"user" => user_fixture()}})
      assert conn |> log_in() |> get(~p"/login") |> redirected_to() == ~p"/dashboard"
    end
  end

  describe "registration" do
    @params %{
      email: "new@mysticlore.test",
      username: "new_mage",
      display_name: "",
      password: "a-long-password"
    }

    test "creates the account and asks to check the mailbox", %{conn: conn} do
      stub_api(%{
        {"POST", "/api/users"} =>
          {201, %{"user" => user_fixture(%{"email" => "new@mysticlore.test"})}}
      })

      html = conn |> post(~p"/register", user: @params) |> html_response(200)
      assert html =~ "Check your email"
      assert html =~ "new@mysticlore.test"
      refute html =~ "/dev/mailbox"

      assert_received {:api, %{path: "/api/users", body: body}}

      assert body == %{
               "email" => "new@mysticlore.test",
               "username" => "new_mage",
               "password" => "a-long-password"
             }
    end

    test "links to the accounts dev mailbox in development only", %{conn: conn} do
      Application.put_env(:web, :dev_hints, true)
      on_exit(fn -> Application.delete_env(:web, :dev_hints) end)
      stub_api(%{{"POST", "/api/users"} => {201, %{"user" => user_fixture()}}})

      html = conn |> post(~p"/register", user: @params) |> html_response(200)
      assert html =~ "http://localhost:4001/dev/mailbox"
    end

    test "shows the validation errors of accounts", %{conn: conn} do
      errors = %{
        "username" => ["has already been taken"],
        "password" => ["should be at least 12 character(s)"]
      }

      stub_api(%{{"POST", "/api/users"} => {422, %{"error" => "invalid", "errors" => errors}}})

      html = conn |> post(~p"/register", user: @params) |> html_response(422)
      assert html =~ "has already been taken"
      assert html =~ "should be at least 12 characters"
      refute html =~ "a-long-password"
    end
  end

  describe "confirmation" do
    test "the link shows a button and the POST confirms the account", %{conn: conn} do
      assert conn |> get(~p"/confirm/abc") |> html_response(200) =~ ~s(id="confirm-form")

      stub_api(%{{"POST", "/api/users/confirm"} => %{"user" => user_fixture()}})
      conn = post(conn, ~p"/confirm/abc")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmed"
      assert_received {:api, %{path: "/api/users/confirm", body: %{"token" => "abc"}}}
    end

    test "an invalid or expired token can't be used", %{conn: conn} do
      stub_api(%{{"POST", "/api/users/confirm"} => {404, %{"error" => "not_found"}}})
      html = conn |> post(~p"/confirm/expired") |> html_response(404)
      assert html =~ "has expired (links last 7 days)"
      assert html =~ ~s(id="confirm-invalid")
      assert html =~ ~s(id="confirm-resend")
    end

    test "resending answers neutrally", %{conn: conn} do
      stub_api(%{{"POST", "/api/users/resend-confirmation"} => {204, nil}})
      conn = post(conn, ~p"/confirm", email: "who@mysticlore.test")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If this address belongs"

      assert_received {:api,
                       %{
                         path: "/api/users/resend-confirmation",
                         body: %{"email" => "who@mysticlore.test"}
                       }}
    end
  end

  test "logout revokes the token at accounts and clears the session", %{conn: conn} do
    test = self()

    stub_api(%{
      {"DELETE", "/api/sessions/current"} => fn conn, _ ->
        ["Bearer " <> internal] = get_req_header(conn, "authorization")

        send(
          test,
          {:headers, get_req_header(conn, "x-session-token"),
           MlShared.InternalToken.verify(internal)}
        )

        {204, nil}
      end
    })

    conn = conn |> log_in("tok-9") |> delete(~p"/logout")

    assert redirected_to(conn) == ~p"/"
    assert_received {:headers, ["tok-9"], {:ok, %{"svc" => "web"}}}
    refute get_session(conn, "session_token")
  end

  test "GET /healthz", %{conn: conn} do
    assert json_response(get(conn, ~p"/healthz"), 200) == %{"status" => "ok"}
  end

  test "security headers with a strict CSP: self-hosted fonts, no third-party origin", %{
    conn: conn
  } do
    conn = get(conn, ~p"/login")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "script-src 'self'"
    assert csp =~ "style-src 'self';"
    assert csp =~ "font-src 'self';"
    refute csp =~ "https://"
    assert csp =~ "frame-ancestors 'none'"
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    html = html_response(conn, 200)
    refute html =~ ~r/style="/
    # the fonts come from this server (preloaded), never from Google
    assert html =~ ~s(href="/fonts/inter-latin-400-normal.woff2")
    refute html =~ "googleapis"
  end

  test "the self-hosted fonts are real WOFF2 files, with their OFL licences" do
    dir = Application.app_dir(:web, "priv/static/fonts")

    fonts =
      for family <- ["cormorant-garamond", "inter", "jetbrains-mono"],
          subset <- ["latin", "latin-ext"],
          weight <-
            %{"cormorant-garamond" => [600], "inter" => [400, 500, 600]}[family] ||
              [400, 500],
          do: "#{family}-#{subset}-#{weight}-normal.woff2"

    assert length(fonts) == 12

    for font <- fonts do
      assert <<"wOF2", _::binary>> = File.read!(Path.join(dir, font)), font
    end

    css = File.read!(Path.expand("../../../assets/css/fonts.css", __DIR__))
    for font <- fonts, do: assert(css =~ "/fonts/#{font}", font)
    assert css =~ "font-display: swap"

    for family <- ["cormorant-garamond", "inter", "jetbrains-mono"],
        do: assert(File.read!(Path.join(dir, "OFL-#{family}.txt")) =~ "SIL Open Font License")
  end

  test "the interface follows Accept-Language (French)", %{conn: conn} do
    html =
      conn
      |> put_req_header("accept-language", "fr-FR,fr;q=0.9,en;q=0.5")
      |> get(~p"/login")
      |> html_response(200)

    assert html =~ ~s(<html lang="fr")
    assert html =~ "Espace membre"
    assert html =~ "Pas encore de compte"
    refute html =~ "Welcome back"
  end
end
