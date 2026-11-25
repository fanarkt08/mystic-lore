defmodule MysticWeb.Admin.ReportsMembersTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.AdminFixtures

  setup do
    %{moderator: staff("moderator"), admin: staff("admin", %{"username" => "clara_dubois"})}
  end

  defp open(conn, user, routes, path) do
    stub_api(Map.merge(member_routes(user), routes))
    {:ok, view, _html} = conn |> log_in() |> live(path)
    view
  end

  describe "report queue" do
    test "social and community reports side by side; a source down degrades alone", ctx do
      routes = %{
        {"GET", "/api/moderation/reports"} => fn conn, _ ->
          case get_req_header(conn, "x-ml-service") do
            ["social"] -> admin_page([social_report()])
            ["community"] -> admin_page([community_report()])
          end
        end
      }

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/reports")
      assert has_element?(view, "#report-social-sr1", "Private message")
      assert has_element?(view, "#report-community-cr1", "Forum reply")
      # the queue never shows a private message
      refute render(view) =~ "Buy cheap"

      view
      |> form("#report-filters", filters: %{source: "forum", status: "open", reason: "all"})
      |> render_change()

      assert_patch(
        view,
        ~p"/admin/reports?#{%{page: 1, reason: "all", source: "forum", status: "open"}}"
      )

      refute has_element?(view, "#report-social-sr1")

      stub_api(
        Map.merge(member_routes(ctx.moderator), %{
          {"GET", "/api/moderation/reports"} => fn conn, _ ->
            if get_req_header(conn, "x-ml-service") == ["social"],
              do: admin_page([social_report()]),
              else: :unavailable
          end
        })
      )

      {:ok, view, _} = ctx.conn |> log_in() |> live(~p"/admin/reports")
      assert has_element?(view, "#community-unavailable")
      assert has_element?(view, "#report-social-sr1")
    end

    test "evidence only after a reason of 10+ characters, then actions", ctx do
      routes = %{
        {"GET", "/api/moderation/reports/sr1"} => %{"report" => social_report()},
        {"POST", "/api/moderation/reports/sr1/evidence"} => %{
          "evidence" => %{
            "body" => "You are useless",
            "sender" => person("u-orion", "hugo_bernard"),
            "sent_at" => "2026-11-23T09:00:00Z",
            "removed" => false
          }
        },
        {"POST", "/api/moderation/reports/sr1/resolve"} => %{"report" => social_report()}
      }

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/reports/social/sr1")
      refute has_element?(view, "#evidence")

      view |> form("#evidence-form", evidence: %{reason: "check it"}) |> render_submit()
      assert has_element?(view, "#evidence-form", "at least 10 characters")
      refute_received {:api, %{path: "/api/moderation/reports/sr1/evidence"}}

      view
      |> form("#evidence-form", evidence: %{reason: "Harassment report review"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/moderation/reports/sr1/evidence",
                         body: %{"reason" => "Harassment report review"}
                       }}

      assert has_element?(view, "#evidence", "You are useless")

      view |> form("#resolve-form", resolve: %{action: "restrict"}) |> render_change()
      assert has_element?(view, "#resolve-duration")

      view
      |> form("#resolve-form",
        resolve: %{action: "restrict", duration_hours: "72", reason: "Repeated insults"}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/moderation/reports/sr1/resolve",
                         body: %{
                           "action" => "restrict",
                           "duration_hours" => 72,
                           "reason" => "Repeated insults"
                         }
                       }}

      assert_redirect(view, ~p"/admin/reports")
    end

    test "forum case file: public snapshot shown, community resolution", ctx do
      routes = %{
        {"GET", "/api/moderation/reports/cr1"} => %{"report" => community_report()},
        {"POST", "/api/moderation/reports/cr1/resolve"} => {409, %{"error" => "already_resolved"}}
      }

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/reports/community/cr1")
      assert has_element?(view, "#snapshot-card", "Buy cheap potions here")
      refute has_element?(view, "#evidence-form")

      view
      |> form("#resolve-form", resolve: %{action: "hide", reason: "Spam link"})
      |> render_submit()

      assert_received {:api, %{body: %{"action" => "hide", "reason" => "Spam link"}}}
      assert render(view) =~ "Someone already handled this"
    end
  end

  describe "members" do
    test "moderator: masked emails, no role form, a forged role event is refused", ctx do
      routes = %{
        {"GET", "/api/admin/users"} => admin_page([member()]),
        {"GET", "/api/admin/users/u-orion"} => %{"user" => member_detail()}
      }

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/members")
      assert has_element?(view, "#member-u-orion", "o•••@mysticlore.test")

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/members/u-orion")
      assert has_element?(view, "#sanction-s1", "Spamming links")
      refute has_element?(view, "#role-form")

      render_hook(view, "set_role", %{"role" => %{"role" => "admin", "reason" => "Forged event"}})
      refute_received {:api, %{method: "PUT"}}
      assert render(view) =~ "Only admins can do that."
    end

    test "staff: reset an avatar with a reason (accounts audits it); refusal stays on the field",
         ctx do
      avatar = %{"kind" => "image", "key" => String.duplicate("c", 32) <> ".jpg"}

      routes = %{
        {"GET", "/api/admin/users/u-orion"} => %{"user" => member_detail(%{"avatar" => avatar})},
        {"POST", "/api/admin/users/u-orion/avatar/reset"} => fn _conn, %{"reason" => reason} ->
          if String.length(reason) < 5,
            do:
              {422,
               %{
                 "error" => "invalid",
                 "errors" => %{"reason" => ["should be 5 to 500 character(s)"]}
               }},
            else: %{"user" => member(%{"avatar" => nil})}
        end
      }

      view = open(ctx.conn, ctx.moderator, routes, ~p"/admin/members/u-orion")
      assert has_element?(view, "#avatar-reset img[src='/media/avatars/#{avatar["key"]}']")

      view |> form("#avatar-reset-form", avatar_reset: %{reason: "bad"}) |> render_submit()
      assert has_element?(view, "#avatar_reset_reason-error", "should be 5 to 500")

      view
      |> form("#avatar-reset-form", avatar_reset: %{reason: "Offensive symbol"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/admin/users/u-orion/avatar/reset",
                         body: %{"reason" => "Offensive symbol"}
                       }}

      assert render(view) =~ "Avatar reset"
    end

    test "staff: restrict with a bounded duration, lift; admin: change a role", ctx do
      routes = %{
        {"GET", "/api/admin/users/u-orion"} => %{"user" => member_detail()},
        {"POST", "/api/admin/users/u-orion/sanctions"} => {201, %{"sanction" => sanction()}},
        {"POST", "/api/admin/sanctions/s1/lift"} => %{"sanction" => sanction()},
        {"PUT", "/api/admin/users/u-orion/role"} => %{"user" => member(%{"role" => "moderator"})}
      }

      view = open(ctx.conn, ctx.admin, routes, ~p"/admin/members/u-orion")

      view |> form("#sanction-form", sanction: %{kind: "restriction"}) |> render_change()

      view
      |> form("#sanction-form",
        sanction: %{kind: "restriction", duration_hours: "168", reason: "Spamming links again"}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/admin/users/u-orion/sanctions",
                         body: %{
                           "kind" => "restriction",
                           "duration_hours" => "168",
                           "reason" => "Spamming links again"
                         }
                       }}

      view |> form("#lift-s1", reason: "Issued by mistake") |> render_submit()
      assert_received {:api, %{path: "/api/admin/sanctions/s1/lift", body: %{"reason" => _}}}

      view
      |> form("#role-form", role: %{role: "moderator", reason: "Trusted helper"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PUT",
                         path: "/api/admin/users/u-orion/role",
                         body: %{"role" => "moderator", "reason" => "Trusted helper"}
                       }}
    end

    test "the last admin and self-demotion are refused by accounts: the message says why", ctx do
      routes = %{
        {"GET", "/api/admin/users/u-orion"} => %{"user" => member_detail(%{"role" => "admin"})},
        {"PUT", "/api/admin/users/u-orion/role"} => {409, %{"error" => "last_admin"}}
      }

      view = open(ctx.conn, ctx.admin, routes, ~p"/admin/members/u-orion")

      view
      |> form("#role-form", role: %{role: "user", reason: "Stepping down"})
      |> render_submit()

      assert render(view) =~ "The academy must keep at least one active admin."
    end
  end
end
