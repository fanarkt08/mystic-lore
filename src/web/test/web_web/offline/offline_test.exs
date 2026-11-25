defmodule MysticWeb.OfflineTest do
  @moduledoc "Leçons hors ligne côté web : service worker, page hors ligne, paquet, synchronisation et purge."
  use MysticWeb.ConnCase, async: true

  @lesson "11111111-2222-4333-8444-555555555555"
  @other "66666666-7777-4888-8999-aaaaaaaaaaaa"

  defp key, do: uuid()

  defp entitlements(user, attrs),
    do: %{
      {"GET", "/api/entitlements/#{user["id"]}"} =>
        Map.merge(
          %{
            "user_id" => user["id"],
            "plan" => "premium",
            "status" => "active",
            "current_period_end" => "2026-12-20T10:00:00Z",
            "cancel_at_period_end" => false
          },
          attrs
        )
    }

  defp ended(user),
    do:
      entitlements(user, %{
        "plan" => "free",
        "status" => "canceled",
        "current_period_end" => "2026-11-01T10:00:00Z"
      })

  defp package(attrs) do
    lesson =
      Map.merge(
        %{
          "id" => @lesson,
          "title" => "Équilibrer les vannes",
          "kind" => "exercise",
          "body" => "Two glass bulbs hiss.\n\nThe engine waits.",
          "content" => %{
            "question" => "What does the balanced engine produce?",
            "choices" => ["Two parts water", "One part water"]
          },
          "xp_reward" => 25,
          "revision" => 3,
          "revised_at" => "2026-11-20T10:00:00Z"
        },
        attrs
      )

    %{
      "package" => %{
        "lesson" => lesson,
        "adventure" => %{
          "slug" => "la-machine-de-l-alchimiste",
          "title" => "La Machine de l'alchimiste"
        },
        "member_id" => "member",
        "downloaded_at" => "2026-11-24T10:00:00Z",
        "expires_at" => "2026-12-08T10:00:00Z",
        "expires_by" => "max_days",
        "max_days" => 14
      }
    }
  end

  defp sync(conn, user, routes, actions) do
    stub_api(Map.merge(member_routes(user), routes))

    conn
    |> log_in()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/offline/sync", Jason.encode!(%{actions: actions}))
    |> json_response(200)
  end

  describe "installable application" do
    test "/sw.js: JavaScript, no-cache, versioned, precaches the static files and the offline page",
         %{
           conn: conn
         } do
      conn = get(conn, ~p"/sw.js")
      body = response(conn, 200)

      assert get_resp_header(conn, "content-type") == ["text/javascript; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]

      assert [version] =
               Regex.run(~r/const VERSION = "([\w-]{16})"/, body, capture: :all_but_first)

      assert version =~ ~r/^[\w-]{16}$/

      [precache] = Regex.run(~r/const PRECACHE = (\[.*\])/, body, capture: :all_but_first)
      precache = Jason.decode!(precache)
      assert "/offline" in precache
      assert "/assets/js/app.js" in precache and "/assets/css/app.css" in precache
      assert "/icons/icon-maskable-512.png" in precache
      assert Enum.any?(precache, &String.starts_with?(&1, "/fonts/"))
      # only static files and the offline page: no page of an account, no API
      assert Enum.all?(precache, &(&1 =~ ~r{^/(assets|fonts|icons)/|^/favicon\.ico$|^/offline$}))

      # the worker never touches what is sent, nor the live connection, and deletes older caches
      assert body =~ ~s|if (request.method !== "GET") return|
      assert body =~ ~s|url.pathname === "/live"|
      assert body =~ ~s|name.startsWith("mysticlore-") && name !== CACHE|
      refute body =~ "<script"
    end

    test "the precache follows the digested asset names of production", %{conn: _conn} do
      assert MysticWeb.OfflineController.precache() |> Enum.member?("/offline")

      # in production `Endpoint.static_path/1` answers the digested path: the worker asks for the same URLs
      assert MysticWeb.Endpoint.static_path("/assets/js/app.js") in MysticWeb.OfflineController.precache()
    end

    test "manifest: name, colours, start page and the three icons; language of the visitor", %{
      conn: conn
    } do
      conn = conn |> put_req_header("accept-language", "fr") |> get(~p"/manifest.webmanifest")
      manifest = Jason.decode!(response(conn, 200))

      assert ["application/manifest+json" <> _] = get_resp_header(conn, "content-type")

      assert %{
               "name" => "MysticLore",
               "display" => "standalone",
               "start_url" => "/dashboard",
               "theme_color" => "#090E20",
               "lang" => "fr"
             } = manifest

      assert Enum.sort(for i <- manifest["icons"], do: {i["sizes"], i["purpose"]}) == [
               {"192x192", "any"},
               {"512x512", "any"},
               {"512x512", "maskable"}
             ]

      for icon <- manifest["icons"] do
        assert File.exists?(Path.join([:code.priv_dir(:web), "static", icon["src"]]))
      end
    end

    test "every page links the manifest", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)
      assert html =~ ~s(<link rel="manifest" href="/manifest.webmanifest">)
    end
  end

  describe "offline page" do
    test "generic: no CSRF token, nothing about the member, only the bundled script, translated texts",
         %{
           conn: conn
         } do
      user = user_fixture(%{"preferences" => %{"language" => "fr", "text_size" => 125}})
      stub_api(member_routes(user))
      conn = conn |> log_in() |> get(~p"/offline")
      html = html_response(conn, 200)

      refute html =~ "csrf-token"
      refute html =~ user["email"]
      refute html =~ user["display_name"]
      # the member's language and display preferences only
      assert html =~ ~s(lang="fr")
      assert html =~ ~s(data-text-size="125")
      assert [_] = Regex.scan(~r/<script/, html)
      assert html =~ ~s(src="/assets/js/app.js")
      assert get_resp_header(conn, "cache-control") == ["no-cache"]

      [texts] = Regex.run(~r/data-texts="([^"]+)"/, html, capture: :all_but_first)
      texts = texts |> unescape() |> Jason.decode!()

      assert texts["answer_saved"] =~ "waiting for synchronization" or
               texts["answer_saved"] =~ "synchronisation"

      assert Map.has_key?(texts, "page_unavailable")
    end

    test "a visitor gets it too (the browser keeps it; it holds no lesson)", %{conn: conn} do
      html = conn |> get(~p"/offline") |> html_response(200)
      assert html =~ ~s(id="offline-app")
      assert html =~ "Offline lessons"
    end
  end

  defp unescape(text),
    do:
      text
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&amp;", "&")

  describe "GET /offline/session" do
    test "401 without a session", %{conn: conn} do
      stub_api(%{})
      conn = get(conn, ~p"/offline/session")
      assert %{"error" => "unauthorized", "message" => message} = json_response(conn, 401)
      assert message =~ "Log in to synchronize"
    end

    test "the member, a CSRF token and the paid access", %{conn: conn} do
      user = user_fixture()
      stub_api(Map.merge(member_routes(user), entitlements(user, %{})))
      body = conn |> log_in() |> get(~p"/offline/session") |> json_response(200)

      assert %{"member_id" => id, "csrf_token" => token, "premium" => true, "message" => nil} =
               body

      assert id == user["id"] and is_binary(token)
    end

    test "an ended access says when (the browser deletes its copies); billing down = unknown", %{
      conn: conn
    } do
      user = user_fixture()
      stub_api(Map.merge(member_routes(user), ended(user)))
      body = conn |> log_in() |> get(~p"/offline/session") |> json_response(200)
      assert %{"premium" => false, "message" => message} = body
      assert message =~ "Your Premium access ended on Nov 1, 2026"

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/entitlements/#{user["id"]}"} => :unavailable
        })
      )

      assert %{"premium" => nil, "message" => nil} =
               build_conn() |> log_in() |> get(~p"/offline/session") |> json_response(200)
    end
  end

  describe "GET /offline/packages/:lesson_id" do
    test "learning's package + the HTML of the lesson page, escaped, never the answer", %{
      conn: conn
    } do
      user = user_fixture()

      evil =
        package(%{
          "body" => "Read <script>alert(1)</script> this.\n\n<img src=x onerror=alert(2)>",
          "content" => %{"question" => "<b>Which?</b>", "choices" => ["A <i>", "B"]}
        })

      stub_api(
        Map.merge(member_routes(user), %{{"GET", "/api/lessons/#{@lesson}/offline"} => evil})
      )

      conn = conn |> log_in() |> get(~p"/offline/packages/#{@lesson}")
      body = json_response(conn, 200)

      assert_received {:api, %{path: "/api/lessons/" <> _}}
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert %{
               "format" => 1,
               "lesson_id" => @lesson,
               "kind" => "exercise",
               "revision" => 3,
               "xp_reward" => 25,
               "expires_at" => "2026-12-08T10:00:00Z",
               "member_id" => "member",
               "adventure" => %{"slug" => "la-machine-de-l-alchimiste"}
             } = body["package"]

      html = body["package"]["html"]
      refute html =~ "<script"
      refute html =~ "<img"
      refute html =~ "<b>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ ~s(name="answer")
      assert html =~ "A &lt;i&gt;"
      refute body |> Jason.encode!() |> String.contains?("solution")
    end

    test "a story: the same paragraphs as the lesson page, no question", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/lessons/#{@lesson}/offline"} =>
            package(%{"kind" => "story", "content" => %{}, "body" => "One.\n\nTwo."})
        })
      )

      html = conn |> log_in() |> get(~p"/offline/packages/#{@lesson}") |> json_response(200)
      html = html["package"]["html"]
      assert html =~ "story-dropcap"
      assert html =~ "<p>One.</p>" or html =~ ~r/<p[^>]*>One\.<\/p>/
      refute html =~ "fieldset"
    end

    test "refusals of learning are explained: 402, 409 no paid period, 422, 404, 503; 401 signed out",
         %{
           conn: conn
         } do
      user = user_fixture()

      for {answer, status, code} <- [
            {{402, %{"error" => "premium_required"}}, 402, "premium_required"},
            {{409, %{"error" => "no_paid_period"}}, 409, "no_paid_period"},
            {{422, %{"error" => "offline_unavailable"}}, 422, "offline_unavailable"},
            {{404, %{"error" => "not_found"}}, 404, "not_found"},
            {:unavailable, 503, "unavailable"}
          ] do
        stub_api(
          Map.merge(member_routes(user), %{{"GET", "/api/lessons/#{@lesson}/offline"} => answer})
        )

        assert %{"error" => ^code, "message" => message} =
                 build_conn()
                 |> log_in()
                 |> get(~p"/offline/packages/#{@lesson}")
                 |> json_response(status)

        assert is_binary(message) and message != ""
      end

      stub_api(%{})

      assert %{"error" => "unauthorized"} =
               conn |> get(~p"/offline/packages/#{@lesson}") |> json_response(401)
    end
  end

  describe "POST /offline/sync" do
    test "replays each action through learning with its key and revision: the server's verdict and XP",
         %{
           conn: conn
         } do
      user = user_fixture()
      [k1, k2] = [key(), key()]

      body =
        sync(
          conn,
          user,
          %{
            {"POST", "/api/lessons/#{@lesson}/submit"} => %{
              "correct" => true,
              "feedback" => "2 H2 + O2 gives 2 H2O.",
              "trace" => nil,
              "xp" => "awarded",
              "xp_reward" => 25,
              "replayed" => false
            },
            {"POST", "/api/lessons/#{@other}/complete"} => %{
              "xp" => "awarded",
              "xp_reward" => 15,
              "replayed" => false
            }
          },
          [
            %{key: k1, lesson_id: @lesson, kind: "submit", answer: "0", revision: 3},
            %{key: k2, lesson_id: @other, kind: "complete", revision: 1}
          ]
        )

      assert_received {:api, %{method: "POST", path: "/api/lessons/" <> _, body: sent}}
      assert sent == %{"answer" => "0", "idempotency_key" => k1, "revision" => 3}

      assert_received {:api,
                       %{method: "POST", body: %{"idempotency_key" => ^k2, "revision" => 1}}}

      assert [
               %{
                 "key" => ^k1,
                 "status" => "done",
                 "correct" => true,
                 "title" => "Well done!",
                 "message" => "2 H2 + O2 gives 2 H2O.",
                 "xp_text" => "+25 XP",
                 "replayed" => false
               },
               %{
                 "key" => ^k2,
                 "status" => "done",
                 "title" => "Marked as read",
                 "xp_text" => "+15 XP"
               }
             ] = body["results"]

      assert body["purge"] == nil
    end

    test "a wrong answer is the server's verdict too; a replay says nothing was counted twice", %{
      conn: conn
    } do
      user = user_fixture()

      body =
        sync(
          conn,
          user,
          %{
            {"POST", "/api/lessons/#{@lesson}/submit"} => %{
              "correct" => false,
              "feedback" => "Count the atoms.",
              "xp" => "none",
              "xp_reward" => 25,
              "replayed" => true
            }
          },
          [%{key: key(), lesson_id: @lesson, kind: "submit", answer: "1", revision: 3}]
        )

      assert [
               %{
                 "status" => "done",
                 "correct" => false,
                 "title" => "Not quite — try again",
                 "xp_text" => "Already synchronized earlier: nothing was counted twice.",
                 "replayed" => true
               }
             ] = body["results"]
    end

    test "a lesson changed since the download: refused with the reason, never graded", %{
      conn: conn
    } do
      user = user_fixture()

      body =
        sync(
          conn,
          user,
          %{
            {"POST", "/api/lessons/#{@lesson}/submit"} =>
              {409, %{"error" => "lesson_changed", "revision" => 4}}
          },
          [%{key: key(), lesson_id: @lesson, kind: "submit", answer: "0", revision: 3}]
        )

      assert [%{"status" => "refused", "reason" => "lesson_changed", "message" => message}] =
               body["results"]

      assert message =~ "wasn't checked against a different statement"
    end

    test "access lost: explicit refusal with the end date, purge, the next actions not even sent",
         %{
           conn: conn
         } do
      user = user_fixture()

      body =
        sync(
          conn,
          user,
          Map.merge(ended(user), %{
            {"POST", "/api/lessons/#{@lesson}/submit"} => {402, %{"error" => "premium_required"}}
          }),
          [
            %{key: key(), lesson_id: @lesson, kind: "submit", answer: "0", revision: 3},
            %{key: key(), lesson_id: @other, kind: "complete", revision: 1}
          ]
        )

      assert [
               %{"status" => "refused", "reason" => "access_ended"},
               %{"status" => "refused", "reason" => "access_ended"}
             ] = body["results"]

      assert body["purge"]["message"] =~ "Your Premium access ended on Nov 1, 2026"
      # only the first action reached learning
      assert_received {:api, %{method: "POST", path: "/api/lessons/" <> first}}
      assert first == "#{@lesson}/submit"
      refute_received {:api, %{method: "POST", path: "/api/lessons/" <> _}}
    end

    test "learning unreachable: the action stays waiting (retry); a damaged action is refused unsent",
         %{
           conn: conn
         } do
      user = user_fixture()

      body =
        sync(conn, user, %{{"POST", "/api/lessons/#{@lesson}/submit"} => :unavailable}, [
          %{key: key(), lesson_id: @lesson, kind: "submit", answer: "0", revision: 3},
          %{key: "not-a-key", lesson_id: @lesson, kind: "submit", answer: "0", revision: 3},
          %{key: key(), lesson_id: @lesson, kind: "submit", answer: "", revision: 3},
          %{key: key(), lesson_id: @lesson, kind: "delete", revision: 3}
        ])

      assert [
               %{"status" => "retry", "reason" => "unavailable"},
               %{"status" => "refused", "reason" => "invalid"},
               %{"status" => "refused", "reason" => "invalid"},
               %{"status" => "refused", "reason" => "invalid"}
             ] = body["results"]
    end

    test "at most 50 actions per request; a body that isn't the expected JSON is 400", %{
      conn: conn
    } do
      user = user_fixture()

      actions =
        for _ <- 1..60, do: %{key: key(), lesson_id: @other, kind: "complete", revision: 1}

      body =
        sync(
          conn,
          user,
          %{{"POST", "/api/lessons/#{@other}/complete"} => %{"xp" => "duplicate"}},
          actions
        )

      assert length(body["results"]) == 50

      assert %{"error" => "bad_request"} =
               build_conn()
               |> log_in()
               |> put_req_header("content-type", "application/json")
               |> post(~p"/offline/sync", "[1, 2")
               |> json_response(400)
    end

    test "signed out: 401, nothing sent", %{conn: conn} do
      stub_api(%{})

      assert %{"error" => "unauthorized"} =
               conn
               |> put_req_header("content-type", "application/json")
               |> post(~p"/offline/sync", Jason.encode!(%{actions: []}))
               |> json_response(401)

      refute_received {:api, %{method: "POST"}}
    end
  end

  describe "live pages" do
    defp lesson_routes(user, offline, extra \\ %{}) do
      lesson = %{
        "lesson" => %{
          "id" => @lesson,
          "title" => "Le fourneau froid",
          "kind" => "story",
          "body" => "The engine is cold.",
          "content" => %{},
          "xp_reward" => 15
        },
        "adventure" => %{
          "slug" => "la-machine-de-l-alchimiste",
          "title" => "La Machine de l'alchimiste"
        },
        "progress" => %{"status" => "in_progress"},
        "prev_id" => nil,
        "next_id" => nil
      }

      lesson = if offline, do: Map.put(lesson, "offline", offline), else: lesson

      member_routes(user)
      |> Map.merge(%{
        {"GET", "/api/adventures/la-machine-de-l-alchimiste"} =>
          adventure_detail(%{"slug" => "la-machine-de-l-alchimiste", "premium" => true}),
        {"GET", "/api/lessons/#{@lesson}"} => lesson
      })
      |> Map.merge(extra)
    end

    test "a premium story offers « Make available offline », disabled until the script checks the device",
         %{
           conn: conn
         } do
      user = user_fixture()
      stub_api(lesson_routes(user, %{"available" => true, "revision" => 2, "max_days" => 14}))

      {:ok, view, _html} =
        conn |> log_in() |> live(~p"/learn/la-machine-de-l-alchimiste/#{@lesson}")

      card = "#offline-copy-#{@lesson}[phx-hook='OfflineLesson'][data-revision='2']"
      assert has_element?(view, card)
      assert has_element?(view, "#offline-download[disabled]", "Make available offline")
      assert has_element?(view, "#offline-open[hidden][href='/offline?lesson=#{@lesson}']")

      assert has_element?(
               view,
               card,
               "14 days at most, and never after the end of your paid period"
             )

      assert has_element?(view, card, "it isn't protected against copying")
      assert has_element?(view, card, "they count on the day they are synchronized")
      # the member is named to the script (the copies of another member are deleted)
      assert has_element?(view, "#offline-notice[data-member='#{user["id"]}'][hidden]")
    end

    test "no card when learning says the lesson can't be kept offline (free lesson, other formats)",
         %{
           conn: conn
         } do
      user = user_fixture()

      for offline <- [%{"available" => false, "revision" => 1, "max_days" => 14}, nil] do
        stub_api(lesson_routes(user, offline))

        {:ok, view, _html} =
          build_conn() |> log_in() |> live(~p"/learn/la-machine-de-l-alchimiste/#{@lesson}")

        refute has_element?(view, ".offline-card")
        refute has_element?(view, "#offline-download")
      end

      _ = conn
    end

    test "an ended access seen on a lesson asks the browser to delete its copies, and says when",
         %{
           conn: conn
         } do
      user = user_fixture()

      stub_api(
        lesson_routes(user, nil, %{
          {"GET", "/api/lessons/#{@lesson}"} => {402, %{"error" => "premium_required"}},
          {"GET", "/api/me/billing"} =>
            billing(user["id"], %{
              "plan" => "free",
              "status" => "canceled",
              "current_period_end" => "2026-11-01T10:00:00Z"
            })
        })
      )

      {:ok, view, _html} =
        conn |> log_in() |> live(~p"/learn/la-machine-de-l-alchimiste/#{@lesson}")

      assert has_element?(view, "#lesson-premium-ended")

      assert_push_event(view, "ml:offline-purge", %{message: message})
      assert message =~ "Your Premium access ended on Nov 1, 2026"
    end

    test "{:entitlements_changed} to a free plan purges the copies on any page; a paid plan doesn't",
         %{
           conn: conn
         } do
      user = user_fixture()
      stub_api(Map.merge(member_routes(user), ended(user)))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/offline")

      send(view.pid, {:entitlements_changed, user["id"], "premium"})
      refute_push_event(view, "ml:offline-purge", %{})

      send(view.pid, {:entitlements_changed, user["id"], "free"})
      assert_push_event(view, "ml:offline-purge", %{message: message})
      assert message =~ "ended on Nov 1, 2026"
    end

    test "settings › Offline lessons: the device's list, synchronization and clearing (script-driven)",
         %{
           conn: conn
         } do
      user = user_fixture()
      stub_api(member_routes(user))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/offline")

      assert has_element?(view, "#settings-nav-offline[aria-current=page]", "Offline lessons")

      assert has_element?(
               view,
               "#offline-settings[phx-hook='OfflineSettings'][phx-update='ignore']"
             )

      assert has_element?(view, "#offline-sync-now[disabled]", "Synchronize now")
      assert has_element?(view, "#offline-clear[disabled]", "Clear offline data")
      assert has_element?(view, "#offline-open-shell[href='/offline']")
      assert has_element?(view, "#offline-settings", "never marked right or wrong there")

      assert has_element?(
               view,
               "#offline-settings",
               "a device that never reconnects keeps it until it expires"
             )
    end

    test "the connection banner knows the offline lessons and links to the offline page", %{
      conn: conn
    } do
      user = user_fixture()
      stub_api(member_routes(user))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/offline")

      assert has_element?(
               view,
               "#connection-status[data-pending='Waiting for synchronization: %{count}']"
             )

      assert has_element?(
               view,
               "#connection-status[data-offline-lessons*='your offline lessons still work']"
             )

      assert has_element?(view, "#connection-offline-link[hidden][href='/offline']")
    end
  end

  describe "logout and texts" do
    test "logout asks the browser to clear this site's storage", %{conn: conn} do
      stub_api(%{{"DELETE", "/api/sessions/current"} => {204, nil}})
      conn = conn |> log_in() |> delete(~p"/logout")
      assert redirected_to(conn) == "/"
      assert get_resp_header(conn, "clear-site-data") == [~s("storage")]
    end

    test "help: how offline lessons work, honestly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help?q=offline")
      assert has_element?(view, "#help-result-offline-lessons", "14 days at most")
      assert has_element?(view, "#help-result-offline-lessons", "never marked right or wrong")

      assert has_element?(
               view,
               "#help-result-offline-lessons",
               "a device that never reconnects keeps it"
             )
    end

    test "cookies and privacy: the service worker, Cache Storage and IndexedDB, version 0.2", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/legal/cookies")

      for entry <- [
            "/sw.js",
            "mysticlore-static-",
            "mysticlore-offline",
            "IndexedDB",
            "Cache Storage"
          ],
          do: assert(has_element?(view, "#storage-table", entry))

      assert has_element?(view, "#offline-storage", "not protected against copying")

      assert has_element?(
               view,
               "#control",
               "Logging out ends your session and asks the browser to delete"
             )

      assert has_element?(view, "#legal-version", "Version 0.2")

      stub_api(%{{"GET", "/api/plans"} => plans("local")})
      {:ok, view, _html} = live(build_conn(), ~p"/legal/privacy")
      assert has_element?(view, "#retention", "Your device (offline lessons)")
      assert has_element?(view, "#retention", "never counted twice")
    end

    test "membership: offline reading is listed with Premium (VIP includes Premium), not with Free",
         %{
           conn: conn
         } do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/plans"} => plans("local"),
          {"GET", "/api/me/billing"} => billing(user["id"]),
          {"GET", "/api/me/credits"} => %{
            "balance" => 20,
            "allocation" => 20,
            "resets_at" => "2026-12-01T00:00:00Z"
          }
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/membership")
      assert has_element?(view, "#plan-premium", "Offline reading: premium stories and quizzes")
      refute has_element?(view, "#plan-free", "Offline reading")
    end
  end
end
