defmodule MysticWeb.AdventureLiveTest do
  use MysticWeb.ConnCase, async: true

  describe "catalogue" do
    test "lists adventures and keeps filters in the URL", %{conn: conn} do
      stub_api(%{
        {"GET", "/api/adventures"} => page([adventure()], %{"total" => 7, "total_pages" => 2})
      })

      {:ok, view, _html} = live(conn, ~p"/adventures")
      assert has_element?(view, "#adventure-la-foret-des-murmures")
      assert has_element?(view, "#results-count", "7 adventures found")
      assert has_element?(view, "#page-next[href='/adventures?page=2']")

      view
      |> form("#filters",
        filters: %{q: "loop", category: "coding", difficulty: "", access: "free", sort: "newest"}
      )
      |> render_change()

      assert_patch(view, ~p"/adventures?access=free&category=coding&q=loop&sort=newest")

      assert_receive {:api,
                      %{
                        path: "/api/adventures",
                        query: %{
                          "access" => "free",
                          "category" => "coding",
                          "q" => "loop",
                          "sort" => "newest"
                        }
                      }}
    end

    test "reads the filters from the URL and ignores unknown values", %{conn: conn} do
      stub_api(%{
        {"GET", "/api/adventures"} => page([adventure()], %{"page" => 2, "total_pages" => 2})
      })

      {:ok, view, _html} = live(conn, ~p"/adventures?difficulty=beginner&category=bogus&page=2")

      assert_receive {:api, %{path: "/api/adventures", query: query}}
      assert query == %{"difficulty" => "beginner", "page" => "2"}
      assert has_element?(view, "#page-prev[href='/adventures?difficulty=beginner']")
    end

    test "empty and unavailable states", %{conn: conn} do
      stub_api(%{{"GET", "/api/adventures"} => page([])})
      {:ok, view, _html} = live(conn, ~p"/adventures?q=nothing")
      assert has_element?(view, "#catalogue-empty")

      stub_api(%{{"GET", "/api/adventures"} => :unavailable})
      {:ok, view, _html} = live(conn, ~p"/adventures")
      assert has_element?(view, "#catalogue-unavailable")
    end
  end

  describe "adventure detail" do
    test "shows objectives, chapters and completed lessons", %{conn: conn} do
      stub_api(%{
        {"GET", "/api/adventures/la-foret-des-murmures"} =>
          adventure_detail(%{"access" => "login_required"})
      })

      {:ok, view, _html} = live(conn, ~p"/adventures/la-foret-des-murmures")

      assert has_element?(view, "h1", "La Forêt des murmures")
      assert has_element?(view, "#lesson-l1", "Completed")
      refute has_element?(view, "#lesson-l2", "Completed")
      assert has_element?(view, "aside", "Understand range(3)")
      assert has_element?(view, "#cta-login[href='/login']")
    end

    test "enroll then go to the first lesson to do", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/adventures/la-foret-des-murmures"} => adventure_detail(),
          {"POST", "/api/adventures/la-foret-des-murmures/enroll"} => %{"enrolled" => true}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/adventures/la-foret-des-murmures")
      view |> element("#cta-enroll") |> render_click()

      assert_redirect(view, ~p"/learn/la-foret-des-murmures/l2")

      assert_received {:api,
                       %{method: "POST", path: "/api/adventures/la-foret-des-murmures/enroll"}}
    end

    test "enrolled members resume where they stopped", %{conn: conn} do
      user = user_fixture()

      detail =
        adventure_detail(%{
          "enrolled" => true,
          "resume_lesson_id" => "l3",
          "progress" => %{"done" => 1, "total" => 3, "percent" => 33}
        })

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/adventures/la-foret-des-murmures"} => detail
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/adventures/la-foret-des-murmures")
      assert has_element?(view, "#cta-resume[href='/learn/la-foret-des-murmures/l3']")
      assert has_element?(view, "[role=progressbar][aria-valuenow='33']")
    end

    test "premium adventures lead to the membership page", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/adventures/la-foret-des-murmures"} =>
            adventure_detail(%{"premium" => true, "access" => "premium_required"})
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/adventures/la-foret-des-murmures")
      assert has_element?(view, "#cta-upgrade[href='/membership']")
      refute has_element?(view, "#lesson-l1 a")
    end

    test "enrolling into a premium adventure without plan shows the upgrade path", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/adventures/la-foret-des-murmures"} => adventure_detail(),
          {"POST", "/api/adventures/la-foret-des-murmures/enroll"} =>
            {402, %{"error" => "premium_required"}}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/adventures/la-foret-des-murmures")
      view |> element("#cta-enroll") |> render_click()
      assert has_element?(view, "#cta-upgrade")
    end

    test "unknown adventure answers 404", %{conn: conn} do
      stub_api(%{{"GET", "/api/adventures/nope"} => {404, %{"error" => "not_found"}}})
      assert_error_sent 404, fn -> get(conn, ~p"/adventures/nope") end
    end

    test "path segments are encoded before reaching learning", %{conn: conn} do
      stub_api(%{})
      assert_error_sent 404, fn -> get(conn, "/adventures/..%2Fme%2Fdashboard") end
      assert_receive {:api, %{path: path}}
      assert path == "/api/adventures/..%2Fme%2Fdashboard"
    end
  end
end
