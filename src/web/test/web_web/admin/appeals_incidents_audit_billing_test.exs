defmodule MysticWeb.Admin.AppealsIncidentsAuditBillingTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.AdminFixtures

  setup do
    %{
      moderator: staff("moderator", %{"id" => "u-theo"}),
      admin: staff("admin", %{"username" => "clara_dubois"})
    }
  end

  defp open(conn, user, routes, path) do
    stub_api(Map.merge(member_routes(user), routes))
    {:ok, view, _html} = conn |> log_in() |> live(path)
    view
  end

  describe "appeals" do
    test "the author of the sanction can't decide; another staff member decides", ctx do
      routes = %{
        {"GET", "/api/admin/appeals"} => admin_page([appeal()]),
        {"POST", "/api/admin/appeals/a1/decide"} => %{"appeal" => %{"status" => "accepted"}}
      }

      # theo issued the sanction
      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/sanctions-appeals")
      assert has_element?(view, "#own-a1")
      refute has_element?(view, "#decide-a1")

      view = open(ctx.conn, ctx.admin, routes, ~p"/admin/sanctions-appeals")

      view
      |> form("#decide-a1", decision: "accept", reason: "Links were legit")
      |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/admin/appeals/a1/decide",
                         body: %{"decision" => "accept", "reason" => "Links were legit"}
                       }}

      assert render(view) =~ "the sanction is lifted"
    end
  end

  describe "incidents" do
    test "open, then resolving needs a summary", ctx do
      routes = %{
        {"GET", "/api/admin/incidents"} => admin_page([incident()]),
        {"POST", "/api/admin/incidents"} => {201, %{"incident" => incident()}},
        {"GET", "/api/admin/incidents/i1"} => %{"incident" => incident()},
        {"POST", "/api/admin/incidents/i1/updates"} =>
          {422, %{"error" => "invalid", "errors" => %{"summary" => ["can't be blank"]}}}
      }

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/incidents")
      assert has_element?(view, "#incident-i1", "Lesson pages slow")

      view
      |> form("#incident-form",
        incident: %{title: "Chat outage", severity: "critical", body: "Down"}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/admin/incidents",
                         body: %{"severity" => "critical"}
                       }}

      assert_redirect(view, ~p"/admin/incidents/i1")

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/incidents/i1")
      assert has_element?(view, "#timeline", "Members report slow lessons.")
      refute has_element?(view, "#update-form textarea[name='update[summary]']")

      view |> form("#update-form", update: %{status: "resolved"}) |> render_change()
      assert has_element?(view, "#update-form textarea[name='update[summary]']")

      view
      |> form("#update-form", update: %{body: "Fixed", status: "resolved", summary: ""})
      |> render_submit()

      assert has_element?(view, "#update-form", "can't be blank")
    end
  end

  describe "audit log" do
    test "admin: filtered list and CSV export link", ctx do
      routes = %{{"GET", "/api/admin/audit"} => admin_page([audit_entry()])}
      view = open(ctx.conn, ctx.admin, routes, ~p"/admin/audit")
      assert has_element?(view, "#audit-7", "social.report.evidence_viewed")

      view
      |> form("#audit-filters",
        filters: %{action: "social.", actor: "theo_garnier", from: "", to: ""}
      )
      |> render_submit()

      assert_patch(view, ~p"/admin/audit?#{%{action: "social.", actor: "theo_garnier"}}")

      assert_received {:api,
                       %{
                         path: "/api/admin/audit",
                         query: %{"action" => "social.", "actor" => "theo_garnier"}
                       }}

      assert has_element?(view, "#export-csv[href*='/admin/audit/export?action=social.']")
    end

    test "the CSV export is proxied as a download, for admins only", ctx do
      csv = "id,action\r\n7,'=HYPERLINK(1)\r\n"

      stub_api(
        Map.merge(member_routes(ctx.admin), %{
          {"GET", "/api/admin/audit/export"} => fn conn, _ ->
            Plug.Conn.put_resp_content_type(conn, "text/csv") |> Plug.Conn.send_resp(200, csv)
          end
        })
      )

      conn = ctx.conn |> log_in() |> get(~p"/admin/audit/export?action=social.")
      assert response(conn, 200) == csv
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment; filename=\"mysticlore-audit-"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert_received {:api, %{path: "/api/admin/audit/export", query: %{"action" => "social."}}}
    end
  end

  describe "billing" do
    test "read-only lists and an idempotent credit adjustment", ctx do
      test = self()

      routes = %{
        {"GET", "/api/admin/subscriptions"} =>
          admin_page([
            %{
              "id" => "sub1",
              "user_id" => "u-mika",
              "plan" => "vip",
              "status" => "active",
              "provider" => "local",
              "current_period_end" => "2026-12-20T00:00:00Z",
              "cancel_at_period_end" => true
            }
          ]),
        {"GET", "/api/admin/webhook-events"} => admin_page([]),
        {"GET", "/api/users"} => %{"users" => [person("u-mika", "ines_petit")]},
        {"GET", "/api/users/by-username/hugo_bernard"} => %{
          "user" => person("u-orion", "hugo_bernard")
        },
        {"POST", "/api/admin/credits/adjustments"} => fn _conn, body ->
          send(test, {:ref, body["ref"]})
          {201, %{"adjustment" => %{"status" => "applied", "amount" => 50, "balance" => 70}}}
        end
      }

      view = open(ctx.conn, ctx.admin, routes, ~p"/admin/billing")
      assert has_element?(view, "#subscription-sub1", "ines_petit")
      assert has_element?(view, "#subscription-sub1", "Ends at period end")
      assert has_element?(view, "#events-empty")

      submit = fn ->
        view
        |> form("#adjust-form",
          credits: %{username: "Hugo_Bernard", amount: "50", reason: "Contest prize"}
        )
        |> render_submit()
      end

      submit.()
      assert_received {:ref, "admin:" <> _ = first}

      assert_received {:api,
                       %{
                         path: "/api/admin/credits/adjustments",
                         body: %{
                           "user_id" => "u-orion",
                           "amount" => "50",
                           "reason" => "Contest prize"
                         }
                       }}

      assert render(view) =~ "50 credits granted. New balance: 70."

      # a new form, a new reference
      submit.()
      assert_received {:ref, second}
      assert second != first
    end
  end
end
