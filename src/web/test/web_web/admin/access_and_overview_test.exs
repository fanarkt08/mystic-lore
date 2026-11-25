defmodule MysticWeb.Admin.AccessAndOverviewTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.AdminFixtures

  @staff_pages ~w(/admin /admin/reports /admin/reports/social/sr1 /admin/members /admin/members/u1
                  /admin/sanctions-appeals /admin/incidents /admin/incidents/i1 /admin/audit /admin/billing)

  describe "access" do
    for path <- @staff_pages do
      test "#{path}: a member gets the 403 page", %{conn: conn} do
        stub_api(member_routes(user_fixture()))

        {403, _headers, body} =
          assert_error_sent(403, fn -> conn |> log_in() |> get(unquote(path)) end)

        assert body =~ "403"
      end
    end

    test "a moderator gets 403 on the admin-only pages and on the CSV export", %{conn: conn} do
      stub_api(member_routes(staff("moderator")))

      for path <- ~w(/admin/audit /admin/billing /admin/audit/export) do
        assert_error_sent(403, fn -> conn |> log_in() |> get(path) end)
      end

      refute_received {:api, %{path: "/api/admin/audit" <> _}}
    end

    test "signed out: sent to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login?return_to=%2Fadmin"}}} = live(conn, ~p"/admin")
    end

    test "the Administration entry is shown to the staff only", %{conn: conn} do
      routes = %{{"GET", "/api/me/sanctions"} => %{"sanctions" => []}}

      stub_api(Map.merge(member_routes(user_fixture()), routes))
      {:ok, view, _} = conn |> log_in() |> live(~p"/account/sanctions")
      refute has_element?(view, "#nav-admin")

      stub_api(Map.merge(member_routes(staff("moderator")), routes))
      {:ok, view, _} = conn |> log_in() |> live(~p"/account/sanctions")
      assert has_element?(view, "#nav-admin[href='/admin']")
    end

    test "a member who loses the staff role is sent away from an open admin page", %{conn: conn} do
      moderator = staff("moderator")
      stub_api(Map.put(member_routes(moderator), {"GET", "/api/admin/stats"}, stats_route()))
      {:ok, view, _} = conn |> log_in() |> live(~p"/admin")

      stub_api(%{
        {"GET", "/api/sessions/current"} => %{"user" => %{moderator | "role" => "user"}}
      })

      send(view.pid, {:role_changed, moderator["id"]})
      assert_redirect(view, "/dashboard")
    end
  end

  describe "overview" do
    test "moderator: real figures, billing never requested, unmeasured values say so", %{
      conn: conn
    } do
      stub_api(
        Map.put(member_routes(staff("moderator")), {"GET", "/api/admin/stats"}, stats_route())
      )

      {:ok, view, _} = conn |> log_in() |> live(~p"/admin")

      assert has_element?(view, "#metric-accounts-0", "6")
      assert has_element?(view, "#metric-social-0", "42")
      assert has_element?(view, "#metric-studio-0", "1")
      assert has_element?(view, "#metric-billing-premium", "Admins only")
      assert has_element?(view, "#metric-latency", "Unavailable — not measured")
      assert has_element?(view, "#metric-uptime", "Unavailable — not measured")
      refute_received {:stats_call, "billing"}
      # the navigation has no admin-only section for a moderator
      refute has_element?(view, "#admin-nav-audit")
    end

    test "admin: billing figures; an unreachable service shows its own tile as unavailable", %{
      conn: conn
    } do
      stub_api(
        Map.put(
          member_routes(staff("admin", %{"username" => "clara_dubois"})),
          {"GET", "/api/admin/stats"},
          stats_route(["community"])
        )
      )

      {:ok, view, _} = conn |> log_in() |> live(~p"/admin")
      assert has_element?(view, "#metric-billing-revenue", "$36")
      assert has_element?(view, "#metric-billing-vip", "1")
      assert has_element?(view, "#tile-community-unavailable")
      refute has_element?(view, "#metric-community-0")
      assert has_element?(view, "#metric-learning-2", "340")
      assert has_element?(view, "#admin-nav-audit")
    end
  end
end
