defmodule MysticWeb.Gamification.DashboardMemberTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.GamificationFixtures

  describe "dashboard" do
    test "daily quests and equipped badges, with a link to the achievements", %{conn: conn} do
      user = user_fixture()
      stub_api(Map.put(member_routes(user), {"GET", "/api/me/dashboard"}, dashboard()))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")

      assert has_element?(view, "#quest-daily-lesson", "Complete a lesson")
      assert has_element?(view, "#quest-daily-lesson", "Completed · +15 XP earned")
      assert has_element?(view, "#quest-daily-lesson", "1 of 1 lesson")
      assert has_element?(view, "#quest-daily-xp", "Reward: 20 XP")
      assert has_element?(view, "#quest-daily-xp", "10 of 30 XP")
      assert has_element?(view, "#quest-daily-xp [role=progressbar][aria-valuenow='10']")

      assert has_element?(view, "#badges", "5 of 10 badges earned")
      assert has_element?(view, "#dashboard-equipped li:first-child", "Main verte")
      assert has_element?(view, "#dashboard-equipped li:last-child", "Bout du chemin")
      assert has_element?(view, "#achievements-link[href='/achievements']")
      # forme existante toujours affichée
      assert has_element?(view, "#level", "Level 2")
    end

    test "each zone degrades on its own", %{conn: conn} do
      user = user_fixture()
      routes = member_routes(user)

      stub_api(
        Map.put(
          routes,
          {"GET", "/api/me/dashboard"},
          dashboard(%{"quests" => [], "equipped_badges" => [], "badges_earned" => 0})
        )
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      assert has_element?(view, "#daily-quests", "No quests today.")
      assert has_element?(view, "#badges", "0 of 10 badges earned")
      assert has_element?(view, "#badges", "No badge equipped yet.")

      stub_api(Map.put(routes, {"GET", "/api/me/dashboard"}, :unavailable))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      assert has_element?(view, "#daily-quests", "Temporarily unavailable")
      assert has_element?(view, "#badges", "Temporarily unavailable")
      assert has_element?(view, "#achievements-link")
    end
  end

  describe "member profile" do
    setup do
      user = user_fixture()
      hugo = member_fixture()

      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/users/by-username/hugo_bernard/profile"} => %{
            "profile" => profile_fixture(hugo)
          },
          {"GET", "/api/me/friends"} => %{"friends" => []},
          {"GET", "/api/me/friend-requests"} => %{"incoming" => [], "outgoing" => []},
          {"GET", "/api/me/blocks"} => %{"blocks" => []}
        })

      %{user: user, hugo: hugo, routes: routes}
    end

    test "shows the member's level, XP, badges and adventures from learning", %{
      conn: conn,
      hugo: hugo,
      routes: routes
    } do
      path = "/api/users/#{hugo["id"]}/profile"

      stub_api(
        Map.put(routes, {"GET", path}, %{
          "user_id" => hugo["id"],
          "level" => 3,
          "xp" => 320,
          "badges_earned" => 4,
          "adventures_completed" => 2,
          "equipped_badges" => [
            equipped_badge(%{
              "slug" => "duel-victor",
              "name" => "Première victoire",
              "icon" => "hero-users"
            })
          ]
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/members/hugo_bernard")

      # l'identifiant vient du profil accounts déjà chargé par la page
      assert_received {:api, %{method: "GET", path: ^path}}
      assert has_element?(view, "#member-record", "Level")
      assert has_element?(view, "#member-record dd", "320")
      assert has_element?(view, "#member-record dd", "4")
      assert has_element?(view, "#member-record dd", "2")
      assert has_element?(view, "#member-equipped", "Première victoire")
      refute has_element?(view, "#manage-badges")
    end

    test "own profile links to the achievements; learning down only affects the record", %{
      conn: conn,
      user: user,
      hugo: hugo,
      routes: routes
    } do
      stub_api(
        Map.merge(routes, %{
          {"GET", "/api/users/by-username/lea_moreau/profile"} => %{
            "profile" => profile_fixture(user)
          },
          {"GET", "/api/users/#{user["id"]}/profile"} => %{
            "user_id" => user["id"],
            "level" => 1,
            "xp" => 0,
            "badges_earned" => 0,
            "adventures_completed" => 0,
            "equipped_badges" => []
          }
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/members/lea_moreau")
      assert has_element?(view, "#manage-badges[href='/achievements']")
      assert has_element?(view, "#member-record", "No badge equipped.")

      stub_api(Map.put(routes, {"GET", "/api/users/#{hugo["id"]}/profile"}, :unavailable))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/members/hugo_bernard")
      assert has_element?(view, "#member-record", "Temporarily unavailable")
      assert has_element?(view, "#member-name", "Hugo Bernard")
    end
  end
end
