defmodule MysticWeb.Pages.ContactAndSupportTest do
  @moduledoc "Formulaire de contact et file du support du staff."
  use MysticWeb.ConnCase, async: true
  import MysticWeb.AdminFixtures

  defp created(reference \\ "REQ-7K3D9-QXA2M", ack \\ "sent"),
    do:
      {201,
       %{
         "request" => %{
           "id" => "r1",
           "reference" => reference,
           "topic" => "bug",
           "status" => "open",
           "inserted_at" => "2026-11-24T10:00:00Z"
         },
         "acknowledgement" => ack
       }}

  @message "The quiz of the forest refuses my answer although it is right."

  describe "contact form" do
    test "a visitor: topic, address and message reach accounts with the page's language", %{
      conn: conn
    } do
      stub_api(%{{"POST", "/api/support/requests"} => fn _conn, _body -> created() end})
      {:ok, view, _html} = live(conn, ~p"/contact?#{[topic: "privacy"]}")
      assert has_element?(view, "#contact-form select option[value='privacy'][selected]")

      view
      |> form("#contact-form",
        contact: %{topic: "bug", email: "visitor@example.test", message: @message}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/support/requests",
                         body: %{
                           "topic" => "bug",
                           "email" => "visitor@example.test",
                           "message" => @message,
                           "locale" => "en"
                         }
                       }}

      assert has_element?(view, "#contact-sent", "REQ-7K3D9-QXA2M")
      assert has_element?(view, "#contact-acknowledged", "doesn't repeat your message")
      refute has_element?(view, "#contact-form")
      refute render(view) =~ "response within"

      view |> element("#contact-again") |> render_click()
      assert has_element?(view, "#contact-form")
    end

    test "a member: no address field (the account's), and their requests with the team's replies",
         %{
           conn: conn
         } do
      user = user_fixture(%{"email" => "lea@example.test"})

      requests = [
        %{
          "id" => "11111111-1111-4111-8111-111111111111",
          "reference" => "REQ-AAAAA-BBBBB",
          "topic" => "billing",
          "message" => "My invoice?",
          "status" => "answered",
          "inserted_at" => "2026-11-20T10:00:00Z",
          "replies" => [
            %{"id" => "p1", "body" => "Here it is.", "inserted_at" => "2026-11-21T10:00:00Z"}
          ]
        }
      ]

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/support/requests"} => %{"requests" => requests},
          {"POST", "/api/support/requests"} => fn _conn, _body -> created() end
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/contact")
      refute has_element?(view, "#contact_email")
      assert has_element?(view, "#contact-member-address", "lea@example.test")

      assert has_element?(
               view,
               "#request-11111111-1111-4111-8111-111111111111",
               "REQ-AAAAA-BBBBB"
             )

      assert has_element?(view, "#reply-p1", "Here it is.")
      assert has_element?(view, "#reply-p1", "Reply from the MysticLore team")

      view
      |> form("#contact-form", contact: %{topic: "billing", message: @message})
      |> render_submit()

      assert_received {:api, %{method: "POST", path: "/api/support/requests", body: body}}
      refute Map.has_key?(body, "email")
      assert has_element?(view, "#contact-acknowledged", "lea@example.test")
    end

    test "the trap field: refused with an explicit message, nothing is sent", %{conn: conn} do
      stub_api(%{})
      {:ok, view, _html} = live(conn, ~p"/contact")

      view
      |> form("#contact-form",
        contact: %{
          topic: "bug",
          email: "bot@example.test",
          message: @message,
          website: "http://spam"
        }
      )
      |> render_submit()

      assert has_element?(view, "#contact-trap", "Leave this field empty")
      refute_received {:api, %{path: "/api/support/requests"}}
      refute has_element?(view, "#contact-sent")
    end

    test "per IP: beyond the limit, refused before reaching accounts", %{conn: conn, ip: ip} do
      {limit, _window} = Application.fetch_env!(:web, :rate_limits)[:contact]
      for _ <- 1..limit, do: MysticWeb.RateLimit.check_ip(ip, :contact)

      stub_api(%{{"POST", "/api/support/requests"} => fn _conn, _body -> created() end})
      {:ok, view, _html} = live(conn, ~p"/contact")

      view
      |> form("#contact-form",
        contact: %{topic: "bug", email: "visitor@example.test", message: @message}
      )
      |> render_submit()

      assert has_element?(view, "#contact-ip-limit")
      refute_received {:api, %{path: "/api/support/requests"}}
    end

    test "service answers: field errors next to the fields, quota per address, ack not sent, outage",
         %{conn: conn} do
      fill = fn view ->
        view
        |> form("#contact-form",
          contact: %{topic: "bug", email: "visitor@example.test", message: @message}
        )
        |> render_submit()
      end

      stub_api(%{
        {"POST", "/api/support/requests"} =>
          {422,
           %{
             "error" => "invalid",
             "errors" => %{"message" => ["must not contain control characters"]}
           }}
      })

      {:ok, view, _html} = live(conn, ~p"/contact")
      fill.(view)
      assert has_element?(view, "#contact_message-error", "must not contain control characters")
      assert has_element?(view, "#contact-invalid")

      stub_api(%{{"POST", "/api/support/requests"} => {429, %{"error" => "rate_limited"}}})
      fill.(view)
      assert has_element?(view, "#contact-quota", "3 acknowledgements in the last 24 hours")

      stub_api(%{
        {"POST", "/api/support/requests"} => fn _conn, _ -> created("REQ-X", "failed") end
      })

      fill.(view)
      assert has_element?(view, "#contact-not-acknowledged", "could not be sent")

      {:ok, view, _html} = live(conn, ~p"/contact")
      stub_api(%{{"POST", "/api/support/requests"} => :unavailable})
      fill.(view)
      assert has_element?(view, "#contact-unavailable", "Nothing was recorded")
    end
  end

  describe "staff support queue" do
    defp request(attrs \\ %{}) do
      Map.merge(
        %{
          "id" => "s1",
          "reference" => "REQ-7K3D9-QXA2M",
          "topic" => "bug",
          "status" => "open",
          "locale" => "en",
          "requester" => %{
            "kind" => "visitor",
            "member" => nil,
            "email" => "v•••@example.test",
            "email_masked" => true
          },
          "replies" => [],
          "message" => @message,
          "internal_note" => nil,
          "inserted_at" => "2026-11-24T10:00:00Z",
          "updated_at" => "2026-11-24T10:00:00Z"
        },
        attrs
      )
    end

    test "a member gets the 403 page; signed out → login", %{conn: conn} do
      stub_api(member_routes(user_fixture()))

      for path <- ["/admin/support", "/admin/support/s1"] do
        assert_error_sent(403, fn -> conn |> log_in() |> get(path) end)
      end

      refute_received {:api, %{path: "/api/admin/support" <> _}}
      assert {:error, {:redirect, %{to: "/login?" <> _}}} = live(build_conn(), ~p"/admin/support")
    end

    test "the queue: loaded once connected, filters in the URL, masked address", %{conn: conn} do
      moderator = staff("moderator")

      stub_api(
        Map.put(
          member_routes(moderator),
          {"GET", "/api/admin/support/requests"},
          page([request(%{"replies" => 0})])
        )
      )

      # the static (HTTP) render asks nothing: an admin's listing is audited by accounts
      dead = conn |> log_in() |> get(~p"/admin/support") |> html_response(200)
      refute dead =~ "REQ-7K3D9-QXA2M"
      refute_received {:api, %{path: "/api/admin/support/requests"}}

      {:ok, view, _html} = conn |> log_in() |> live(~p"/admin/support")
      assert has_element?(view, "#support-s1", "REQ-7K3D9-QXA2M")
      assert has_element?(view, "#support-s1", "v•••@example.test")
      assert has_element?(view, "#admin-nav-support[aria-current='page']")
      assert_received {:api, %{path: "/api/admin/support/requests", query: %{"status" => "open"}}}

      view
      |> form("#support-filters", filter: %{status: "all", topic: "privacy", q: " REQ-7 "})
      |> render_submit()

      assert_patch(view, ~p"/admin/support?#{[q: "REQ-7", status: "all", topic: "privacy"]}")
      assert_received {:api, %{path: "/api/admin/support/requests", query: query}}
      assert query == %{"page" => "1", "q" => "REQ-7", "topic" => "privacy"}
    end

    test "a request: message, reply by e-mail (honest when the e-mail failed), status and note",
         %{
           conn: conn
         } do
      moderator = staff("moderator")
      sent = request(%{"status" => "answered", "replies" => [reply("sent")]})

      stub_api(
        Map.merge(member_routes(moderator), %{
          {"GET", "/api/admin/support/requests/s1"} => %{"request" => request()},
          {"POST", "/api/admin/support/requests/s1/replies"} => {201, %{"request" => sent}},
          {"PATCH", "/api/admin/support/requests/s1"} => %{
            "request" => request(%{"status" => "closed", "internal_note" => "Done"})
          }
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/admin/support/s1")
      assert has_element?(view, "#support-message", @message)
      assert has_element?(view, "#support-audit-note")

      view
      |> form("#support-reply-form", reply: %{body: "Fixed this morning."})
      |> render_submit()

      assert_received {:api, %{method: "POST", body: %{"body" => "Fixed this morning."}}}
      assert has_element?(view, "#support-reply-p1", "e-mail sent")
      assert render(view) =~ "Reply sent by e-mail."

      stub_api(
        Map.merge(member_routes(moderator), %{
          {"POST", "/api/admin/support/requests/s1/replies"} =>
            {201, %{"request" => request(%{"replies" => [reply("failed")]})}}
        })
      )

      view |> form("#support-reply-form", reply: %{body: "Second try."}) |> render_submit()
      assert has_element?(view, "#support-reply-p1", "e-mail not sent")
      assert render(view) =~ "the e-mail could not be sent"

      stub_api(
        Map.merge(member_routes(moderator), %{
          {"PATCH", "/api/admin/support/requests/s1"} => %{
            "request" => request(%{"status" => "closed", "internal_note" => "Done"})
          }
        })
      )

      view
      |> form("#support-manage-form", manage: %{status: "closed", internal_note: "Done"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         body: %{"status" => "closed", "internal_note" => "Done"}
                       }}

      assert has_element?(view, "#support-closed-note")
      refute has_element?(view, "#support-reply-form")
    end

    test "unknown request: an explicit state; a closed one refuses the reply (409)", %{conn: conn} do
      moderator = staff("moderator")

      stub_api(
        Map.put(
          member_routes(moderator),
          {"GET", "/api/admin/support/requests/gone"},
          {404, %{"error" => "not_found"}}
        )
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/admin/support/gone")
      assert has_element?(view, "#support-not-found")

      stub_api(
        Map.merge(member_routes(moderator), %{
          {"GET", "/api/admin/support/requests/s1"} => %{"request" => request()},
          {"POST", "/api/admin/support/requests/s1/replies"} => {409, %{"error" => "closed"}}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/admin/support/s1")
      view |> form("#support-reply-form", reply: %{body: "Hello there"}) |> render_submit()
      assert render(view) =~ "This request is closed: reopen it before answering."
    end

    test "erasing a request: admins only (the Guard refuses a moderator's event before any call)",
         %{
           conn: conn
         } do
      moderator = staff("moderator")

      stub_api(
        Map.put(member_routes(moderator), {"GET", "/api/admin/support/requests/s1"}, %{
          "request" => request()
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/admin/support/s1")
      refute has_element?(view, "#erase-support")
      render_click(view, "delete", %{})
      refute_received {:api, %{method: "DELETE"}}
      assert render(view) =~ "Only admins can do that."

      admin = staff("admin")

      stub_api(
        Map.merge(member_routes(admin), %{
          {"GET", "/api/admin/support/requests/s1"} => %{"request" => request()},
          {"DELETE", "/api/admin/support/requests/s1"} => {204, nil}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/admin/support/s1")

      assert {:error, {:live_redirect, %{to: "/admin/support"}}} =
               view |> element("#erase-support") |> render_click()

      assert_received {:api, %{method: "DELETE", path: "/api/admin/support/requests/s1"}}
    end

    test "losing the staff role while the page is open: sent away, no call", %{conn: conn} do
      moderator = staff("moderator")

      stub_api(
        Map.put(member_routes(moderator), {"GET", "/api/admin/support/requests/s1"}, %{
          "request" => request()
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/admin/support/s1")

      stub_api(%{
        {"GET", "/api/sessions/current"} => %{"user" => %{moderator | "role" => "user"}}
      })

      send(view.pid, {:role_changed, moderator["id"]})
      assert_redirect(view, "/dashboard")
    end
  end

  defp reply(status),
    do: %{
      "id" => "p1",
      "body" => "Fixed this morning.",
      "author" => %{"id" => "a1", "username" => "theo_garnier", "display_name" => "Théo Garnier"},
      "email_status" => status,
      "inserted_at" => "2026-11-24T11:00:00Z"
    }
end
