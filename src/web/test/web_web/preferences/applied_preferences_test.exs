defmodule MysticWeb.Preferences.AppliedTest do
  @moduledoc "Preferences applied on every page: language, <html> attributes, VIP theme, time zone."
  use MysticWeb.ConnCase, async: true

  defp member(prefs, attrs \\ %{}) do
    user_fixture(
      Map.merge(
        %{
          "interests" => [],
          "avatar" => nil,
          "preferences" =>
            Map.merge(
              %{
                "language" => "auto",
                "time_zone" => "auto",
                "theme" => "system",
                "reduce_motion" => false,
                "high_contrast" => false,
                "text_size" => 100,
                "underline_links" => false,
                "captions" => true,
                "daily_xp_goal" => 20
              },
              prefs
            )
        },
        attrs
      )
    )
  end

  defp html_tag(html), do: html |> LazyHTML.from_document() |> LazyHTML.query("html")
  defp attr(html, name), do: html |> html_tag() |> LazyHTML.attribute(name) |> List.first()

  describe "language" do
    test "a member's language wins over Accept-Language, and sets <html lang>", %{conn: conn} do
      user = member(%{"language" => "fr"})
      stub_api(member_routes(user))

      html =
        conn
        |> put_req_header("accept-language", "en-US,en;q=0.9")
        |> log_in()
        |> get(~p"/settings/preferences")
        |> html_response(200)

      assert attr(html, "lang") == "fr"

      user = member(%{"language" => "auto"})
      stub_api(member_routes(user))

      html =
        build_conn()
        |> put_req_header("accept-language", "fr-FR,fr;q=0.9")
        |> log_in()
        |> get(~p"/dashboard")
        |> html_response(200)

      assert attr(html, "lang") == "fr"
    end

    test "visitor selector: SameSite cookie, local return only, the cookie beats Accept-Language",
         %{conn: conn} do
      stub_api(%{})
      conn = conn |> get(~p"/adventures")
      assert html_response(conn, 200) =~ ~s(id="locale-form")

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_req_header("accept-language", "en")
        |> post(~p"/locale", %{"locale" => "fr", "return_to" => "/adventures?page=2"})

      assert redirected_to(conn) == "/adventures?page=2"
      assert %{value: "fr", same_site: "Lax", http_only: true} = conn.resp_cookies["ml_locale"]

      html =
        build_conn()
        |> put_req_cookie("ml_locale", "fr")
        |> put_req_header("accept-language", "en-US")
        |> get(~p"/adventures")
        |> html_response(200)

      assert attr(html, "lang") == "fr"

      for bad <- [
            "https://evil.test/x",
            "//evil.test",
            "/\\evil.test",
            "javascript:alert(1)",
            "/ok\r\nx"
          ] do
        conn =
          build_conn()
          |> Plug.Test.init_test_session(%{})
          |> post(~p"/locale", %{"locale" => "fr", "return_to" => bad})

        assert redirected_to(conn) == "/", "#{inspect(bad)} must not be followed"
      end

      # unknown language: no cookie
      conn =
        build_conn() |> Plug.Test.init_test_session(%{}) |> post(~p"/locale", %{"locale" => "de"})

      refute conn.resp_cookies["ml_locale"]
    end

    test "the selector is protected against CSRF", %{conn: conn} do
      assert_error_sent 403, fn ->
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/locale", %{"locale" => "fr", "_csrf_token" => "forged"})
      end
    end
  end

  test "<html> carries the accessibility and theme attributes of the member", %{conn: conn} do
    user =
      member(%{
        "theme" => "light",
        "reduce_motion" => true,
        "high_contrast" => true,
        "text_size" => 125,
        "underline_links" => true
      })

    stub_api(member_routes(user))
    html = conn |> log_in() |> get(~p"/dashboard") |> html_response(200)

    assert attr(html, "data-theme") == "light"
    assert attr(html, "data-motion") == "reduce"
    assert attr(html, "data-contrast") == "more"
    assert attr(html, "data-text-size") == "125"
    assert attr(html, "data-links") == "underline"
    assert html =~ ~s(<meta name="color-scheme" content="light">)

    # defaults: only the theme
    stub_api(%{})
    html = build_conn() |> get(~p"/") |> html_response(200)
    assert attr(html, "data-theme") == "system"
    refute attr(html, "data-motion") || attr(html, "data-text-size")
  end

  describe "VIP theme" do
    test "applied only while billing reports VIP; otherwise paused, with a notice", %{conn: conn} do
      user = member(%{"theme" => "grove"})
      entitlements = "/api/entitlements/#{user["id"]}"

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", entitlements} => %{"plan" => "vip", "status" => "active"}
        })
      )

      html = conn |> log_in() |> get(~p"/dashboard") |> html_response(200)
      assert attr(html, "data-theme") == "grove"

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", entitlements} => %{"plan" => "premium", "status" => "active"},
          {"GET", "/api/me/billing"} => billing(user["id"], %{"plan" => "premium"})
        })
      )

      html = build_conn() |> log_in() |> get(~p"/settings/preferences") |> html_response(200)
      assert attr(html, "data-theme") == "system"

      {:ok, view, _html} = build_conn() |> log_in() |> live(~p"/settings/preferences")
      assert has_element?(view, "#theme-paused", "Moonlit grove")

      # billing unreachable: not verified, not applied
      stub_api(Map.merge(member_routes(user), %{{"GET", entitlements} => :unavailable}))
      html = build_conn() |> log_in() |> get(~p"/dashboard") |> html_response(200)
      assert attr(html, "data-theme") == "system"
    end

    test "follows {:entitlements_changed, id, plan} while the page is open", %{conn: conn} do
      user = member(%{"theme" => "ember"})

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/entitlements/#{user["id"]}"} => %{"plan" => "vip", "status" => "active"},
          {"GET", "/api/me/dashboard"} => :unavailable,
          {"GET", "/api/me/billing"} => :unavailable,
          {"GET", "/api/me/friend-requests"} => :unavailable
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")

      send(view.pid, {:entitlements_changed, user["id"], "free"})
      assert_push_event(view, "ml:prefs", %{attrs: %{"data-theme" => "system"}})

      send(view.pid, {:entitlements_changed, user["id"], "vip"})
      assert_push_event(view, "ml:prefs", %{attrs: %{"data-theme" => "ember"}, scheme: "dark"})
    end
  end

  describe "time zone" do
    @session %{
      "id" => "s1",
      "user_agent" => "Mozilla/5.0 Chrome/131.0 Safari/537.36",
      "ip" => nil,
      "inserted_at" => "2026-11-20T10:00:00Z",
      "last_used_at" => "2026-11-23T09:30:00Z",
      "current" => true
    }

    defp sessions_page(conn, user, connect_params \\ %{}) do
      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/2fa"} => %{
            "enabled" => false,
            "enabled_at" => nil,
            "recovery_codes_left" => 0
          },
          {"GET", "/api/me/sessions"} => %{"sessions" => [@session]}
        })
      )

      {:ok, view, _html} =
        conn |> log_in() |> put_connect_params(connect_params) |> live(~p"/settings/security")

      view
    end

    test "an explicit zone converts the displayed times and names the zone", %{conn: conn} do
      view = sessions_page(conn, member(%{"time_zone" => "Asia/Tokyo"}))
      # 09:30 UTC = 18:30 in Tokyo
      assert has_element?(view, "#session-s1", "18:30 JST")
    end

    test "auto: the browser's zone (validated), UTC when unknown", %{conn: conn} do
      view = sessions_page(conn, member(%{}), %{"tz" => "America/New_York"})
      assert has_element?(view, "#session-s1", "04:30 EST")

      view = sessions_page(build_conn(), member(%{}), %{"tz" => "Not/AZone"})
      assert has_element?(view, "#session-s1", "09:30 UTC")
    end
  end

  test "video lessons: the caption track is `default` only with the preference" do
    content = %{
      "video" => %{"src" => "/media/lessons/v.webm", "type" => "video/webm", "poster" => nil},
      "duration_s" => 34,
      "captions" => [
        %{"lang" => "en", "label" => "English", "src" => "/media/lessons/v.en.vtt"},
        %{"lang" => "fr", "label" => "Français", "src" => "/media/lessons/v.fr.vtt"}
      ],
      "transcript" => "Look up."
    }

    on =
      render_component(&MysticWeb.LessonFormats.video_lesson/1,
        lesson_id: "l1",
        content: content,
        watched: 0,
        transcript_open: false,
        transcript_seen: false,
        completed: false,
        captions_on: true
      )

    assert on =~ ~r/<track[^>]*srclang="en"[^>]*default/

    off =
      render_component(&MysticWeb.LessonFormats.video_lesson/1,
        lesson_id: "l1",
        content: content,
        watched: 0,
        transcript_open: false,
        transcript_seen: false,
        completed: false,
        captions_on: false
      )

    refute off =~ ~r/<track[^>]*default/
  end
end
