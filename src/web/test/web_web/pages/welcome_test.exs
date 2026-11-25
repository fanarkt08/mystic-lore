defmodule MysticWeb.Pages.WelcomeTest do
  @moduledoc """
  Accueil guidé : proposé après la connexion d'un compte confirmé dont l'accueil est `pending`, chaque étape
  enregistrée par les API d'accounts, étapes passées ou accueil sauté, relance depuis les paramètres.
  """
  use MysticWeb.ConnCase, async: true

  @login %{email: "new@mysticlore.test", password: "a-long-password"}

  defp pending(attrs \\ %{}),
    do:
      user_fixture(
        Map.merge(
          %{
            "onboarding" => %{"status" => "pending", "at" => nil},
            "interests" => [],
            "preferences" => %{"language" => "auto", "time_zone" => "auto"}
          },
          attrs
        )
      )

  describe "after the login" do
    test "a confirmed account with a pending tour goes to /welcome (no « welcome back »)", %{
      conn: conn
    } do
      stub_api(%{
        {"POST", "/api/sessions"} => {201, %{"session_token" => "t", "user" => pending()}}
      })

      conn = post(conn, ~p"/login", user: @login)
      assert redirected_to(conn) == ~p"/welcome"
      refute Phoenix.Flash.get(conn.assigns.flash, :info)
    end

    test "a finished or skipped tour: the dashboard", %{conn: conn} do
      for status <- ~w(completed skipped) do
        user =
          user_fixture(%{"onboarding" => %{"status" => status, "at" => "2026-11-24T10:00:00Z"}})

        stub_api(%{{"POST", "/api/sessions"} => {201, %{"session_token" => "t", "user" => user}}})
        assert conn |> post(~p"/login", user: @login) |> redirected_to() == ~p"/dashboard"
      end
    end

    test "the page asked before the login wins, also through the two-factor step", %{conn: conn} do
      conn = get(conn, ~p"/login?#{[return_to: "/messages/c1", reason: "expired"]}")
      html = html_response(conn, 200)
      assert html =~ ~s(id="session-expired")
      assert html =~ "go back to the page you were on"

      stub_api(%{
        {"POST", "/api/sessions"} => %{"two_factor_required" => true, "challenge" => "ch"},
        {"POST", "/api/sessions/2fa"} => {201, %{"session_token" => "t", "user" => pending()}}
      })

      conn = conn |> recycle() |> post(~p"/login", user: @login)
      assert redirected_to(conn) == ~p"/login/2fa"

      conn =
        conn
        |> recycle()
        |> post(~p"/login/2fa", two_factor: %{one_time_password: "123456"})

      assert redirected_to(conn) == "/messages/c1"
      # the page to come back to doesn't survive the login
      refute get_session(conn, "user_return_to")
    end

    test "never another site, nor a guest page", %{conn: conn} do
      for bad <- ["https://evil.example/", "//evil.example/x", "/login", "/register"] do
        conn = get(conn, ~p"/login?#{[return_to: bad]}")
        refute get_session(conn, "user_return_to")
      end
    end

    test "already signed in: /login?return_to= goes there", %{conn: conn} do
      stub_api(%{{"GET", "/api/sessions/current"} => %{"user" => user_fixture()}})

      assert conn |> log_in() |> get(~p"/login?#{[return_to: "/friends"]}") |> redirected_to() ==
               "/friends"
    end
  end

  describe "the steps" do
    setup %{conn: conn} do
      user = pending()
      %{user: user, conn: log_in(conn)}
    end

    defp saved(user, changes), do: %{"user" => Map.merge(user, changes)}

    test "language and time zone: saved by accounts, then the next step (announced)", %{
      conn: conn,
      user: user
    } do
      stub_api(
        Map.put(member_routes(user), {"PATCH", "/api/me/preferences"}, fn _conn, body ->
          saved(user, %{"preferences" => Map.merge(user["preferences"], body)})
        end)
      )

      {:ok, view, _html} = live(conn, ~p"/welcome")

      assert has_element?(
               view,
               "#welcome-steps li[aria-current='step']",
               "Language and time zone"
             )

      refute has_element?(view, "#welcome-back")

      view
      |> form("#welcome-language-form", welcome: %{language: "auto", time_zone: "Europe/Paris"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         path: "/api/me/preferences",
                         body: %{"language" => "auto", "time_zone" => "Europe/Paris"}
                       }}

      assert_patch(view, ~p"/welcome?#{[step: "interests"]}")
      assert has_element?(view, "#welcome-status", "Language and time zone saved.")
      assert has_element?(view, "#welcome-back[href='/welcome?step=language']")
    end

    test "a refused value stays on the step, the service's error next to the field", %{
      conn: conn,
      user: user
    } do
      stub_api(
        Map.put(
          member_routes(user),
          {"PATCH", "/api/me/preferences"},
          {422,
           %{"error" => "invalid", "errors" => %{"time_zone" => ["is not a known time zone"]}}}
        )
      )

      {:ok, view, _html} = live(conn, ~p"/welcome")

      view
      |> form("#welcome-language-form", welcome: %{language: "en", time_zone: "auto"})
      |> render_submit()

      assert has_element?(view, "#welcome-time-zone-error", "is not a known time zone")
      assert has_element?(view, "#welcome-language-form")
    end

    test "interests (PATCH /api/me) and goal; « Skip this step » saves nothing", %{
      conn: conn,
      user: user
    } do
      stub_api(
        Map.merge(member_routes(user), %{
          {"PATCH", "/api/me"} => fn _conn, body -> saved(user, body) end,
          {"PATCH", "/api/me/preferences"} => fn _conn, body ->
            saved(user, %{"preferences" => Map.merge(user["preferences"], body)})
          end
        })
      )

      {:ok, view, _html} = live(conn, ~p"/welcome?#{[step: "interests"]}")

      view
      |> form("#welcome-interests-form", welcome: %{interests: ["", "astronomy", "coding"]})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         path: "/api/me",
                         body: %{"interests" => ["astronomy", "coding"]}
                       }}

      assert_patch(view, ~p"/welcome?#{[step: "goal"]}")

      view |> element("#welcome-skip-step") |> render_click()
      assert_patch(view, ~p"/welcome?#{[step: "accessibility"]}")
      refute_received {:api, %{method: "PATCH", path: "/api/me/preferences"}}

      view
      |> form("#welcome-accessibility-form",
        welcome: %{reduce_motion: "true", high_contrast: "false", text_size: "125"}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/me/preferences",
                         body: %{
                           "reduce_motion" => true,
                           "high_contrast" => false,
                           "text_size" => "125"
                         }
                       }}

      assert_patch(view, ~p"/welcome?#{[step: "adventures"]}")
    end

    test "the last step: real recommendations for the interests; finishing records « completed »",
         %{
           conn: conn
         } do
      user = pending(%{"interests" => ["astronomy", "mythology"]})

      done =
        Map.put(user, "onboarding", %{"status" => "completed", "at" => "2026-11-24T10:00:00Z"})

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/dashboard"} => %{
            "recommendations" => [adventure(), adventure(%{"slug" => "the-starlit-sum"})]
          },
          {"PUT", "/api/me/onboarding"} => %{"user" => done}
        })
      )

      {:ok, view, _html} = live(conn, ~p"/welcome?#{[step: "adventures"]}")

      assert_received {:api,
                       %{
                         path: "/api/me/dashboard",
                         query: %{"categories" => "science,humanities"}
                       }}

      assert has_element?(view, "#welcome-adventure-la-foret-des-murmures")
      refute has_element?(view, "#welcome-skip-step")

      assert {:error, {:live_redirect, %{to: "/adventures/the-starlit-sum"}}} =
               view |> element("#welcome-start-the-starlit-sum") |> render_click()

      assert_received {:api,
                       %{
                         method: "PUT",
                         path: "/api/me/onboarding",
                         body: %{"status" => "completed"}
                       }}
    end

    test "« Skip the welcome tour » records « skipped » and opens the dashboard", %{
      conn: conn,
      user: user
    } do
      stub_api(
        Map.put(member_routes(user), {"PUT", "/api/me/onboarding"}, fn _conn, %{"status" => s} ->
          saved(user, %{"onboarding" => %{"status" => s, "at" => "2026-11-24T10:00:00Z"}})
        end)
      )

      {:ok, view, _html} = live(conn, ~p"/welcome?#{[step: "goal"]}")

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               view |> element("#welcome-skip-tour") |> render_click()

      assert_received {:api, %{method: "PUT", body: %{"status" => "skipped"}}}
    end

    test "learning or accounts unavailable: said, never a fake success", %{conn: conn, user: user} do
      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/dashboard"} => :unavailable,
          {"PUT", "/api/me/onboarding"} => :unavailable
        })
      )

      {:ok, view, _html} = live(conn, ~p"/welcome?#{[step: "adventures"]}")
      assert has_element?(view, "#welcome-recommendations-unavailable")
      view |> element("#welcome-finish") |> render_click()
      assert render(view) =~ "temporarily unavailable"
      assert has_element?(view, "#welcome-finish")
    end

    test "restarted from the settings: pending again, then the tour", %{conn: conn, user: user} do
      done = Map.put(user, "onboarding", %{"status" => "completed"})

      stub_api(
        Map.merge(member_routes(done), %{
          {"GET", "/api/me/billing"} => billing(user["id"]),
          {"PUT", "/api/me/onboarding"} => %{"user" => user}
        })
      )

      {:ok, view, _html} = live(conn, ~p"/settings/preferences")

      assert {:error, {:live_redirect, %{to: "/welcome"}}} =
               view |> element("#restart-onboarding") |> render_click()

      assert_received {:api,
                       %{
                         method: "PUT",
                         path: "/api/me/onboarding",
                         body: %{"status" => "pending"}
                       }}
    end
  end
end
