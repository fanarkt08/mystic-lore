defmodule MysticWeb.Security.SettingsSecurityTest do
  use MysticWeb.ConnCase, async: true

  @off %{"enabled" => false, "enabled_at" => nil, "recovery_codes_left" => 0}
  @on %{"enabled" => true, "enabled_at" => "2026-11-20T10:00:00Z", "recovery_codes_left" => 10}
  @codes Enum.map(1..10, &"abcd-efgh-jkmn-#{1000 + &1}")
  @setup %{
    "secret" => "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP",
    "otpauth_uri" =>
      "otpauth://totp/MysticLore:lyra@mysticlore.test?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=MysticLore",
    "qr_svg" => ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>)
  }

  defp session(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "user_agent" =>
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_1) AppleWebKit/605.1.15 Version/18.1 Safari/605.1.15",
        "ip" => "203.0.113.0",
        "inserted_at" => "2026-11-20T10:00:00Z",
        "last_used_at" => "2026-11-23T09:00:00Z",
        "current" => false
      },
      attrs
    )
  end

  defp routes(user, extra) do
    user
    |> member_routes()
    |> Map.merge(%{
      {"GET", "/api/me/2fa"} => @off,
      {"GET", "/api/me/sessions"} => %{"sessions" => [session("s-here", %{"current" => true})]}
    })
    |> Map.merge(extra)
  end

  # Function route that reports the x-session-token header it received.
  defp report_token(response) do
    test = self()

    fn conn, _body ->
      send(test, {:session_header, get_req_header(conn, "x-session-token")})
      response
    end
  end

  setup do
    %{user: user_fixture()}
  end

  describe "two-factor authentication" do
    test "set up with the password, scan the QR code, confirm a code, see the codes once", %{
      conn: conn,
      user: user
    } do
      stub_api(
        routes(user, %{
          {"POST", "/api/me/2fa/setup"} => fn _conn, %{"password" => password} ->
            if password == "my-password",
              do: @setup,
              else: {401, %{"error" => "invalid_credentials"}}
          end,
          {"POST", "/api/me/2fa/enable"} => fn _conn, %{"code" => code} ->
            if code == "123456",
              do: %{"recovery_codes" => @codes},
              else: {401, %{"error" => "invalid_code"}}
          end
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/security")
      assert has_element?(view, "#two-factor-status", "Off")

      view
      |> form("#two-factor-setup-form", two_factor_setup: %{password: "wrong"})
      |> render_submit()

      assert has_element?(
               view,
               "#two_factor_setup_password-error",
               "This is not your current password."
             )

      view
      |> form("#two-factor-setup-form", two_factor_setup: %{password: "my-password"})
      |> render_submit()

      assert has_element?(view, ~s(#two-factor-qr[src^="data:image/svg+xml;base64,"]))
      assert has_element?(view, "#two-factor-secret", "JBSW Y3DP EHPK 3PXP")

      view
      |> form("#two-factor-enable-form", two_factor_enable: %{one_time_password: "000000"})
      |> render_submit()

      assert has_element?(
               view,
               "#two_factor_enable_one_time_password-error",
               "This code is not valid."
             )

      stub_api(
        routes(user, %{
          {"GET", "/api/me/2fa"} => @on,
          {"POST", "/api/me/2fa/enable"} => %{"recovery_codes" => @codes}
        })
      )

      view
      |> form("#two-factor-enable-form", two_factor_enable: %{one_time_password: " 123456 "})
      |> render_submit()

      assert_received {:api, %{path: "/api/me/2fa/enable", body: %{"code" => "123456"}}}
      assert render(view) =~ "Two-factor authentication is on."
      assert has_element?(view, "#recovery-codes li", "abcd-efgh-jkmn-1001")
      assert has_element?(view, ~s(#recovery-codes a[download="mysticlore-recovery-codes.txt"]))
      assert has_element?(view, "#two-factor-status", "10 recovery codes left")
      refute has_element?(view, "#two-factor-qr")

      view |> element("#hide-recovery-codes") |> render_click()
      refute has_element?(view, "#recovery-codes")
    end

    test "turn off with the password and a code; regenerate the recovery codes", %{
      conn: conn,
      user: user
    } do
      stub_api(
        routes(user, %{
          {"GET", "/api/me/2fa"} => @on,
          {"POST", "/api/me/2fa/recovery-codes"} => %{"recovery_codes" => @codes},
          {"POST", "/api/me/2fa/disable"} => {401, %{"error" => "invalid_code"}}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/security")
      assert has_element?(view, "#two-factor-status", "On")

      view
      |> form("#recovery-codes-form", recovery_codes: %{password: "my-password"})
      |> render_submit()

      assert has_element?(view, "#recovery-codes li", "abcd-efgh-jkmn-1010")

      view
      |> form("#two-factor-disable-form",
        two_factor_disable: %{password: "my-password", one_time_password: "999999"}
      )
      |> render_submit()

      assert has_element?(
               view,
               "#two_factor_disable_one_time_password-error",
               "This code is not valid."
             )

      stub_api(routes(user, %{{"POST", "/api/me/2fa/disable"} => {204, nil}}))

      view
      |> form("#two-factor-disable-form",
        two_factor_disable: %{password: "my-password", one_time_password: "123456"}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/me/2fa/disable",
                         body: %{"password" => "my-password", "code" => "123456"}
                       }}

      assert render(view) =~ "Two-factor authentication is off."
      assert has_element?(view, "#two-factor-status", "Off")
    end

    test "too many failed attempts are explained", %{conn: conn, user: user} do
      stub_api(routes(user, %{{"POST", "/api/me/2fa/setup"} => {429, %{"error" => "locked"}}}))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/security")

      view
      |> form("#two-factor-setup-form", two_factor_setup: %{password: "x"})
      |> render_submit()

      assert render(view) =~ "please wait 15 minutes"
    end
  end

  describe "active sessions" do
    test "lists the sessions, signs one out, or all the others", %{conn: conn, user: user} do
      sessions = [
        session("s-here", %{
          "current" => true,
          "user_agent" => "Mozilla/5.0 (Windows NT 10.0) Chrome/131.0 Safari/537.36"
        }),
        session("s-other", %{"ip" => nil})
      ]

      stub_api(
        routes(user, %{
          {"GET", "/api/me/sessions"} => report_token(%{"sessions" => sessions}),
          {"DELETE", "/api/me/sessions/s-other"} => report_token({204, nil}),
          {"DELETE", "/api/me/sessions"} => report_token({204, nil})
        })
      )

      {:ok, view, _html} = conn |> log_in("tok-here") |> live(~p"/settings/security")
      assert_received {:session_header, ["tok-here"]}

      assert has_element?(view, "#session-s-here", "Chrome on Windows")
      assert has_element?(view, "#session-s-here", "This browser")
      assert has_element?(view, "#session-s-here", "network 203.0.113.0")
      refute has_element?(view, "#session-s-here button")
      assert has_element?(view, "#session-s-other", "Safari on macOS")

      view |> element("#session-s-other button", "Sign out") |> render_click()
      assert_received {:api, %{method: "DELETE", path: "/api/me/sessions/s-other"}}
      assert_received {:session_header, ["tok-here"]}
      assert render(view) =~ "That session has been signed out."

      view |> element("#revoke-other-sessions") |> render_click()
      assert_received {:api, %{method: "DELETE", path: "/api/me/sessions"}}
      assert render(view) =~ "All your other sessions have been signed out."
    end

    test "the list reloads when a session is revoked elsewhere", %{conn: conn, user: user} do
      stub_api(routes(user, %{}))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/security")
      assert has_element?(view, "#session-s-here")

      stub_api(
        routes(user, %{
          {"GET", "/api/me/sessions"} => %{
            "sessions" => [session("s-here", %{"current" => true}), session("s-new")]
          }
        })
      )

      MlShared.Events.broadcast("user:#{user["id"]}", {:sessions_revoked, user["id"]})
      assert render(view) =~ "session-s-new"
    end

    test "accounts unavailable: the sections say so, the page works", %{conn: conn, user: user} do
      stub_api(
        routes(user, %{
          {"GET", "/api/me/2fa"} => :unavailable,
          {"GET", "/api/me/sessions"} => :unavailable
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/security")
      assert has_element?(view, "#two-factor-unavailable")
      assert has_element?(view, "#sessions-unavailable")
      refute has_element?(view, "#settings-nav-profile[aria-current]")
      assert has_element?(view, "#settings-nav-security[aria-current=page]")
    end
  end

  describe "email and password" do
    test "a new address is confirmed by email; errors stay on their field", %{
      conn: conn,
      user: user
    } do
      stub_api(
        routes(user, %{
          {"POST", "/api/me/email"} => fn _conn, %{"password" => password} ->
            if password == "my-password",
              do: {204, nil},
              else: {401, %{"error" => "invalid_credentials"}}
          end
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/account")

      view
      |> form("#email-form", email_change: %{email: "new@mysticlore.test", password: "bad"})
      |> render_submit()

      assert has_element?(
               view,
               "#email_change_password-error",
               "This is not your current password."
             )

      assert has_element?(view, ~s(#email_change_email[value="new@mysticlore.test"]))

      view
      |> form("#email-form",
        email_change: %{email: " new@mysticlore.test ", password: "my-password"}
      )
      |> render_submit()

      assert_received {:api, %{path: "/api/me/email", body: %{"email" => "new@mysticlore.test"}}}
      assert has_element?(view, "#email-change-sent", "new@mysticlore.test")

      errors = %{"email" => ["has already been taken"]}

      stub_api(
        routes(user, %{
          {"POST", "/api/me/email"} => {422, %{"error" => "invalid", "errors" => errors}}
        })
      )

      view
      |> form("#email-form",
        email_change: %{email: "taken@mysticlore.test", password: "my-password"}
      )
      |> render_submit()

      assert has_element?(view, "#email_change_email-error", "has already been taken")
    end

    test "the password change keeps the current session; too many failures are explained", %{
      conn: conn,
      user: user
    } do
      stub_api(routes(user, %{{"PUT", "/api/me/password"} => report_token({204, nil})}))
      {:ok, view, _html} = conn |> log_in("tok-here") |> live(~p"/settings/account")

      view
      |> form("#password-form",
        password: %{current_password: "old-password", password: "a-brand-new-password"}
      )
      |> render_submit()

      assert_received {:session_header, ["tok-here"]}
      assert render(view) =~ "Password changed."

      stub_api(routes(user, %{{"PUT", "/api/me/password"} => {429, %{"error" => "locked"}}}))

      view
      |> form("#password-form",
        password: %{current_password: "old-password", password: "a-brand-new-password"}
      )
      |> render_submit()

      assert render(view) =~ "please wait 15 minutes"
    end
  end

  describe "confirmation of the new address" do
    test "a button applies the change", %{conn: conn, user: user} do
      stub_api(
        Map.put(member_routes(user), {"POST", "/api/me/email/confirm"}, %{
          "user" => Map.put(user, "email", "new@mysticlore.test")
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/confirm-email/tok-mail")
      refute_received {:api, %{path: "/api/me/email/confirm"}}

      view |> element("#confirm-email-button") |> render_click()
      assert_received {:api, %{path: "/api/me/email/confirm", body: %{"token" => "tok-mail"}}}
      assert render(view) =~ "From now on, log in with new@mysticlore.test."
    end

    for {status, message} <- [
          {404, "This link can't be used"},
          {422, "Address no longer available"}
        ] do
      test "explains a #{status}", %{conn: conn, user: user} do
        stub_api(
          Map.put(
            member_routes(user),
            {"POST", "/api/me/email/confirm"},
            {unquote(status), %{"error" => "x"}}
          )
        )

        {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/confirm-email/tok")
        view |> element("#confirm-email-button") |> render_click()
        assert has_element?(view, "#confirm-email", unquote(message))
      end
    end

    test "needs a signed-in member", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login?return_to=%2Fsettings%2Fconfirm-email%2Ftok"}}} =
               live(conn, ~p"/settings/confirm-email/tok")
    end
  end

  describe "{:sessions_revoked, user_id}" do
    test "open pages whose session was revoked go to /login", %{conn: conn, user: user} do
      stub_api(Map.merge(routes(user, %{}), %{{"POST", "/api/me/email/confirm"} => {404, %{}}}))
      {:ok, settings, _html} = conn |> log_in() |> live(~p"/settings/security")
      # a view without handle_info/2 of its own is signed out too
      {:ok, confirm, _html} = conn |> log_in() |> live(~p"/settings/confirm-email/tok")

      stub_api(%{{"GET", "/api/sessions/current"} => {401, %{"error" => "unauthorized"}}})
      MlShared.Events.broadcast("user:#{user["id"]}", {:sessions_revoked, user["id"]})

      # the login page explains it (reason=expired) and brings the member back to the page afterwards
      assert {"/login?reason=expired&return_to=%2Fsettings%2Fsecurity", flash} =
               assert_redirect(settings)

      assert flash == %{}

      assert {"/login?reason=expired&return_to=%2Fsettings%2Fconfirm-email%2Ftok", _} =
               assert_redirect(confirm)
    end

    test "a page whose session is still valid stays open", %{conn: conn, user: user} do
      stub_api(routes(user, %{}))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/security")

      MlShared.Events.broadcast("user:#{user["id"]}", {:sessions_revoked, user["id"]})
      assert render(view) =~ "Active sessions"
      assert_received {:api, %{path: "/api/sessions/current"}}
    end

    test "accounts unreachable: the page stays open", %{conn: conn, user: user} do
      stub_api(routes(user, %{}))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/security")

      stub_api(routes(user, %{{"GET", "/api/sessions/current"} => :unavailable}))
      MlShared.Events.broadcast("user:#{user["id"]}", {:sessions_revoked, user["id"]})
      assert render(view) =~ "Active sessions"
    end
  end
end
