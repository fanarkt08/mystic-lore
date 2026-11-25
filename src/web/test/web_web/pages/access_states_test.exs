defmodule MysticWeb.Pages.AccessStatesTest do
  @moduledoc """
  États explicites d'un accès terminé ou d'un lien qui ne marche plus, état « indisponible » avec un « Réessayer »
  qui recharge vraiment, bandeau de connexion, pages d'erreur et page d'accueil.
  """
  use MysticWeb.ConnCase, async: true

  defp lesson_routes(user, extra) do
    Map.merge(
      member_routes(user),
      Map.merge(
        %{
          {"GET", "/api/adventures/la-machine-de-l-alchimiste"} =>
            adventure_detail(%{"slug" => "la-machine-de-l-alchimiste", "premium" => true}),
          {"GET", "/api/lessons/l9"} => %{
            "lesson" => %{
              "id" => "l9",
              "title" => "Transmutation",
              "kind" => "story",
              "body" => "Gold.",
              "content" => %{},
              "xp_reward" => 10
            },
            "adventure" => %{
              "slug" => "la-machine-de-l-alchimiste",
              "title" => "La Machine de l'alchimiste"
            },
            "progress" => %{"status" => "in_progress"},
            "prev_id" => nil,
            "next_id" => nil
          }
        },
        extra
      )
    )
  end

  describe "premium access" do
    test "never subscribed: « part of a Premium adventure », upgrade", %{conn: conn} do
      user = user_fixture()

      stub_api(
        lesson_routes(user, %{
          {"GET", "/api/lessons/l9"} => {402, %{"error" => "premium_required"}},
          {"GET", "/api/me/billing"} => billing(user["id"])
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/learn/la-machine-de-l-alchimiste/l9")
      assert has_element?(view, "#lesson-premium", "part of a Premium adventure")
      assert has_element?(view, "#lesson-upgrade[href='/membership']")
      refute has_element?(view, "#lesson-premium-ended")
    end

    test "an ended subscription: « your Premium access ended on … », renew", %{conn: conn} do
      user = user_fixture()

      ended =
        billing(user["id"], %{
          "plan" => "free",
          "status" => "canceled",
          "current_period_end" => "2026-11-01T10:00:00Z"
        })

      stub_api(
        lesson_routes(user, %{
          {"GET", "/api/lessons/l9"} => {402, %{"error" => "premium_required"}},
          {"GET", "/api/me/billing"} => ended
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/learn/la-machine-de-l-alchimiste/l9")

      assert has_element?(
               view,
               "#lesson-premium-ended",
               "Your Premium access ended on Nov 1, 2026"
             )

      assert has_element?(view, "#lesson-renew[href='/membership']")
    end

    test "the plan ends while the premium lesson is open: said at once (polite), then back on renewal",
         %{conn: conn} do
      user = user_fixture()

      stub_api(lesson_routes(user, %{}))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/learn/la-machine-de-l-alchimiste/l9")
      assert has_element?(view, "#lesson-l9")

      stub_api(
        lesson_routes(user, %{
          {"GET", "/api/me/billing"} =>
            billing(user["id"], %{"plan" => "free", "status" => "canceled"})
        })
      )

      send(view.pid, {:entitlements_changed, user["id"], "free"})

      assert has_element?(
               view,
               "#lesson-premium-ended[role='status']",
               "Your Premium access has ended"
             )

      refute has_element?(view, "#lesson-l9")

      stub_api(lesson_routes(user, %{}))
      send(view.pid, {:entitlements_changed, user["id"], "premium"})
      assert has_element?(view, "#lesson-l9")
    end

    test "a free adventure is not touched by the end of a plan", %{conn: conn} do
      user = user_fixture()

      stub_api(
        lesson_routes(user, %{
          {"GET", "/api/adventures/la-machine-de-l-alchimiste"} =>
            adventure_detail(%{"slug" => "la-machine-de-l-alchimiste", "premium" => false})
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/learn/la-machine-de-l-alchimiste/l9")
      send(view.pid, {:entitlements_changed, user["id"], "free"})
      assert has_element?(view, "#lesson-l9")
    end
  end

  describe "VIP theme" do
    setup do
      user = user_fixture(%{"preferences" => %{"theme" => "grove"}})
      %{user: user}
    end

    test "ended: the dashboard says when, with « Renew VIP »", %{conn: conn, user: user} do
      ended =
        billing(user["id"], %{
          "plan" => "free",
          "status" => "canceled",
          "current_period_end" => "2026-11-02T10:00:00Z"
        })

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/entitlements/#{user["id"]}"} => ended["entitlements"],
          {"GET", "/api/me/billing"} => ended
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      assert has_element?(view, "#vip-ended", "Your VIP access ended on Nov 2, 2026")
      assert has_element?(view, "#vip-renew[href='/membership']")

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/preferences")
      assert has_element?(view, "#theme-paused", "Your VIP access ended on Nov 2, 2026")
      assert has_element?(view, "#theme-paused-renew[href='/membership']")
    end

    test "billing unreachable: paused, but never « ended »", %{conn: conn, user: user} do
      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/entitlements/#{user["id"]}"} => :unavailable,
          {"GET", "/api/me/billing"} => :unavailable
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      assert has_element?(view, "#vip-ended", "Your VIP theme is paused")
      refute has_element?(view, "#vip-ended", "ended")
    end

    test "ended while a page is open: the paused theme is said", %{conn: conn, user: user} do
      vip = billing(user["id"], %{"plan" => "vip", "status" => "active"})

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/entitlements/#{user["id"]}"} => vip["entitlements"],
          {"GET", "/api/me/billing"} => vip
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      refute has_element?(view, "#vip-ended")

      send(view.pid, {:entitlements_changed, user["id"], "free"})
      assert render(view) =~ "Your VIP access has ended: your VIP theme is paused."
    end
  end

  describe "unavailable, with a real retry" do
    test "« Try again » mounts the page again: every service is asked again", %{conn: conn} do
      user = user_fixture()
      stub_api(Map.put(member_routes(user), {"GET", "/api/me/sanctions"}, :unavailable))

      {:ok, view, _html} = conn |> log_in() |> live(~p"/account/sanctions")
      assert has_element?(view, "#sanctions-unavailable-retry")

      assert {:error, {:live_redirect, %{to: "/account/sanctions"}}} =
               view |> element("#sanctions-unavailable-retry") |> render_click()
    end
  end

  describe "expired links and closed checkouts" do
    test "invitation to a full activity: explicit state, check again", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"POST", "/api/links/preview"} => %{
            "lobby" => %{
              "id" => "lb",
              "title" => "Relay",
              "host" => %{"display_name" => "Hugo"},
              "member_count" => 4,
              "max_players" => 4
            }
          },
          {"POST", "/api/links/join"} => {409, %{"error" => "full"}}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/multiplayer/join/tok-1234567890abcdef")
      assert has_element?(view, "#invitation-full")
      view |> element("#join-link") |> render_click()
      assert has_element?(view, "#link-invalid[role='status']", "This activity is full")
    end

    test "an expired checkout: no payment, start a new one", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/checkout/cs_old"} => %{
            "session_id" => "cs_old",
            "plan" => "premium",
            "status" => "expired",
            "mode" => "local"
          },
          {"GET", "/api/plans"} => plans("local")
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/membership/local-checkout/cs_old")
      assert has_element?(view, "#checkout-closed", "This checkout has expired")
      assert has_element?(view, "#checkout-restart[href='/membership']")
    end

    test "an e-mail change link that can't be used: why, and where to ask for a new one", %{
      conn: conn
    } do
      user = user_fixture()

      stub_api(
        Map.put(
          member_routes(user),
          {"POST", "/api/me/email/confirm"},
          {404, %{"error" => "not_found"}}
        )
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/confirm-email/tok")
      view |> element("#confirm-email-button") |> render_click()
      assert has_element?(view, "#confirm-email-invalid", "links last 24 hours")
      assert has_element?(view, "#confirm-email-invalid a[href='/settings/account']")
    end

    test "a reset link that can't be used", %{conn: conn} do
      stub_api(%{{"GET", "/api/password-resets/old"} => {404, %{"error" => "not_found"}}})
      html = conn |> get(~p"/reset-password/old") |> html_response(404)
      assert html =~ ~s(id="reset-invalid")
      assert html =~ ~s(href="/forgot-password")
    end
  end

  describe "connection, errors, landing" do
    test "the connection banner is in every shell: polite status, texts for the script, a real button",
         %{
           conn: conn
         } do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~s(id="connection-status")
      assert html =~ ~s(role="status")
      assert html =~ ~s(data-offline="You seem to be offline.)
      assert html =~ ~s(data-reconnecting="Connection lost. Reconnecting…")
      assert html =~ ~s(id="connection-retry")
      # no inline script anywhere (CSP)
      refute html =~ ~r/<script(?![^>]*src=)[^>]*>\s*\S/
    end

    test "error pages link to the help center and the contact form" do
      for template <- ~w(403.html 404.html 500.html) do
        html =
          template
          |> MysticWeb.ErrorHTML.render(%{})
          |> Phoenix.HTML.Safe.to_iodata()
          |> IO.iodata_to_binary()

        assert html =~ ~s(id="error-help-link")
        assert html =~ ~s(href="/contact")
        refute html =~ "googleapis"
      end
    end

    test "landing: static studio example (no AI call), no testimonial and no rating, help links",
         %{conn: conn} do
      stub_api(%{
        {"GET", "/api/adventures"} => page([adventure()]),
        {"GET", "/api/plans"} => plans("local")
      })

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#studio-preview", "Example — static illustration")
      assert has_element?(view, "#studio-preview", "no AI is called on this page")
      assert has_element?(view, "#studio-preview-link[href='/studio']")
      refute_received {:api, %{path: "/api/ai" <> _}}
      refute_received {:api, %{path: "/api/projects" <> _}}

      # aucun avis inventé : pas de section de témoignages
      refute has_element?(view, "#testimonials")
      refute has_element?(view, "[id^='testimonial-']")
      refute render(view) =~ ~r/★|☆|\d(\.\d)? ?\/ ?5\b/

      assert has_element?(view, "#home-help[href='/help']")
      assert has_element?(view, "#home-contact[href='/contact']")
      assert has_element?(view, "#home-legal[href='/legal']")
      assert has_element?(view, "#faq-more[href='/help']")
    end

    test "a support reply notification: its sentence and its link to the member's request" do
      id = "11111111-1111-4111-8111-111111111111"

      n = %{
        "kind" => "support_replied",
        "category" => "account",
        "params" => %{"request_id" => id}
      }

      assert MysticWeb.Notifications.text(n) =~ "answered your support request"
      assert MysticWeb.Notifications.path(n) == "/contact#request-#{id}"

      assert MysticWeb.Notifications.path(%{n | "params" => %{"request_id" => "x/../y"}}) ==
               "/contact"
    end
  end
end
