defmodule MysticWeb.Pages.LegalAndHelpTest do
  @moduledoc """
  Pages juridiques provisoires (bandeau, version, emplacements à compléter, inventaire des cookies et du stockage,
  sous-traitants de ce serveur), liens qui y mènent, et centre d'aide avec sa recherche côté serveur.
  """
  use MysticWeb.ConnCase, async: true

  describe "legal pages" do
    test "every document: provisional banner, version and date, operator placeholders", %{
      conn: conn
    } do
      stub_api(%{{"GET", "/api/plans"} => plans("local")})

      for doc <- ~w(privacy terms cookies accessibility) do
        {:ok, view, html} = live(conn, ~p"/legal/#{doc}")

        assert has_element?(
                 view,
                 "#legal-banner",
                 "Provisional text, to be validated by a lawyer"
               )

        # vie privée, cookies et accessibilité en sont à la version 0.2, les conditions à la 0.1
        version = if doc in ~w(privacy cookies accessibility), do: "0.2", else: "0.1"
        assert has_element?(view, "#legal-version", "Version #{version} · last updated")
        assert has_element?(view, "#legal-nav-#{doc}[aria-current='page']")
        # never an invented company: explicit gaps
        assert html =~ "To be completed by the operator"
        # no claim of compliance: the banner says so, and nothing claims the opposite
        assert html =~ "claims no certified compliance"
        refute html =~ ~r/(is|are) (fully )?(GDPR|RGPD|WCAG)[- ]compliant|conforms to WCAG/i
      end
    end

    test "/legal: the documents and the operator's identity, all to be completed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/legal")

      for doc <- ~w(privacy terms cookies accessibility),
          do: assert(has_element?(view, "#legal-doc-#{doc}[href='/legal/#{doc}']"))

      for field <- ~w(entity address registration director host dpo),
          do: assert(has_element?(view, "#operator-#{field}.legal-placeholder"))

      assert has_element?(view, "#legal-contact[href='/contact?topic=privacy']")
    end

    test "unknown document → 404", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, ~p"/legal/imprint") end)
    end

    test "cookies: the real inventory, and why there is no consent banner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/legal/cookies")

      for name <- ~w(_mystic_web ml_locale __phoenix_flash__ __phoenix_reload_status__),
          do: assert(has_element?(view, "#cookie-table", name))

      for entry <- ~w(phx:nav-history-position phx:fallback:LongPoll phx:live-socket:debug),
          do: assert(has_element?(view, "#storage-table", entry))

      assert has_element?(view, "#storage-table", "consecutive-reloads")
      assert has_element?(view, "#no-banner", "no fake banner")
    end

    test "privacy: retention per service, rights with links, processors as configured HERE", %{
      conn: conn
    } do
      stub_api(%{{"GET", "/api/plans"} => plans("local")})
      {:ok, view, _html} = live(conn, ~p"/legal/privacy")

      assert has_element?(view, "#retention", "90 days, 500 per member")
      assert has_element?(view, "#retention", "180 days after they are closed")
      assert has_element?(view, "#rights-export[href='/settings/data']")
      assert has_element?(view, "#rights-delete[href='/settings/data']")
      assert has_element?(view, "#rights-contact[href='/contact?topic=privacy']")
      assert has_element?(view, "#processor-stripe-status", "simulated locally")
      # a visitor: the AI provider is shown to members only, never guessed
      assert has_element?(view, "#processor-ai-status", "Shown to signed-in members")
      assert has_element?(view, "#email-provider.legal-placeholder")
      refute_received {:api, %{path: "/api/ai"}}
    end

    test "privacy for a member: the studio's real provider and their own « share my drafts » choice",
         %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/plans"} => plans("stripe"),
          {"GET", "/api/ai"} => %{
            "provider" => "anthropic",
            "demo" => false,
            "configured" => true,
            "external" => true,
            "share_drafts_with_ai" => false
          }
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/legal/privacy")
      assert has_element?(view, "#processor-stripe-status", "Stripe keys are configured")
      assert has_element?(view, "#processor-ai-status", "only the brief you type is sent")

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/plans"} => :unavailable,
          {"GET", "/api/ai"} => %{"provider" => "demo", "demo" => true, "configured" => true}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/legal/privacy")
      assert has_element?(view, "#processor-stripe-status", "Unknown right now")
      assert has_element?(view, "#processor-ai-status", "Local demo generator")
    end

    test "linked from the public footer, the sign-up page and the data settings", %{conn: conn} do
      stub_api(%{
        {"GET", "/api/adventures"} => page([]),
        {"GET", "/api/plans"} => plans("local")
      })

      {:ok, view, _html} = live(conn, ~p"/")

      for {id, path} <- [
            {"footer-privacy-link", "/legal/privacy"},
            {"footer-terms-link", "/legal/terms"},
            {"footer-cookies-link", "/legal/cookies"},
            {"footer-accessibility-link", "/legal/accessibility"},
            {"footer-help-link", "/help"},
            {"footer-contact-link", "/contact"}
          ],
          do: assert(has_element?(view, "##{id}[href='#{path}']"))

      html = conn |> get(~p"/register") |> html_response(200)
      assert html =~ ~s(id="register-terms")
      assert html =~ ~s(href="/legal/privacy")

      user = user_fixture()
      stub_api(Map.put(member_routes(user), {"GET", "/api/me/exports"}, %{"exports" => []}))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/data")
      assert has_element?(view, "#data-privacy-link[href='/legal/privacy']")
      assert has_element?(view, "#data-cookies-link[href='/legal/cookies']")
      assert has_element?(view, "#data-contact-link[href='/contact?topic=privacy']")
      # the member rail too
      assert has_element?(view, "#rail-legal[href='/legal']")
      assert has_element?(view, "#rail-help[href='/help']")
    end
  end

  describe "help center" do
    test "topics and questions, each answer linking to its page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")
      assert has_element?(view, "#help-topic-account[href='#topic-account']")
      assert has_element?(view, "#topic-privacy #help-export", "How do I get a copy of my data?")
      assert has_element?(view, "#help-export a[href='/settings/data']")
      assert has_element?(view, "#help-contact-link[href='/contact']")
      refute has_element?(view, "#help-results")
    end

    test "search works WITHOUT JavaScript: a plain GET filtered on the server", %{conn: conn} do
      html = conn |> get(~p"/help?#{[q: "password"]}") |> html_response(200)
      assert html =~ ~s(id="help-search")
      assert html =~ ~s(method="get")
      assert html =~ ~s(id="help-result-forgot-password")
      refute html =~ ~s(id="help-result-xp")
      assert html =~ "answers for « password »" or html =~ "answer for « password »"
    end

    test "every word must match, accents and case ignored; no result offers the contact form", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/help?#{[q: "ÉXPORT data"]}")
      assert has_element?(view, "#help-result-export")
      refute has_element?(view, "#help-result-cookies")

      {:ok, view, _html} = live(conn, ~p"/help?#{[q: "zzzz qqqq"]}")
      assert has_element?(view, "#help-results-status", "0 answers")
      assert has_element?(view, "#help-no-result a[href='/contact']")
    end

    test "once live, the same form patches the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")
      view |> form("#help-search", %{q: "cancel"}) |> render_submit()
      assert_patch(view, ~p"/help?#{[q: "cancel"]}")
      assert has_element?(view, "#help-result-cancel")

      view |> form("#help-search", %{q: "  "}) |> render_submit()
      assert_patch(view, ~p"/help")
      refute has_element?(view, "#help-results")
    end

    test "a long query is cut to 100 characters" do
      assert String.length(MysticWeb.Help.query(String.duplicate("a", 300))) == 100
      assert MysticWeb.Help.search("") == MysticWeb.Help.entries()
    end
  end
end
