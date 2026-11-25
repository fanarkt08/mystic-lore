defmodule MysticWeb.Gamification.AchievementsLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.GamificationFixtures

  setup do
    user = user_fixture()
    %{user: user, routes: member_routes(user)}
  end

  defp put_equipped(routes, response),
    do: Map.put(routes, {"PUT", "/api/me/badges/equipped"}, response)

  test "lists earned and locked badges in words, with progress and the equip slots", %{
    conn: conn,
    routes: routes
  } do
    stub_api(Map.put(routes, {"GET", "/api/me/achievements"}, achievements(catalogue())))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/achievements")

    assert has_element?(view, "#badge-sprout-tender", "Earned")
    assert has_element?(view, "#badge-sprout-tender", "Equipped in slot 1")
    assert has_element?(view, "#badge-sprout-tender", "Uncommon")
    assert has_element?(view, "#badge-trailblazer", "Earned on Nov 21, 2026")
    assert has_element?(view, "#badge-five-hundred-runes", "Locked")
    assert has_element?(view, "#badge-five-hundred-runes", "155 of 500 XP")

    assert has_element?(
             view,
             "#badge-five-hundred-runes [role=progressbar][aria-valuenow='155'][aria-valuemax='500']"
           )

    assert has_element?(view, "#badge-moonlit-week", "5 of 7 days in a row")
    # seuls les badges gagnés s'équipent
    assert has_element?(view, "#equip-trailblazer")
    refute has_element?(view, "#equip-five-hundred-runes")

    assert has_element?(view, "#equipped", "1 of 3 slots used")
    assert has_element?(view, "#badges", "2 of 4 earned")
    assert has_element?(view, "#slot-1", "Main verte")
    assert has_element?(view, "#slot-2", "Empty")
    assert has_element?(view, "#slot-1-up[disabled]")
    assert has_element?(view, "button#slot-1-unequip[aria-label='Unequip Main verte']")
    assert has_element?(view, "#equip-status[role=status]")
    assert has_element?(view, "#equip-error[role=alert]")
  end

  test "equip, move and unequip send the whole ordered list and announce the result", %{
    conn: conn,
    routes: routes
  } do
    badges = catalogue()

    stub_api(
      routes
      |> Map.put({"GET", "/api/me/achievements"}, achievements(badges))
      |> put_equipped(fn _conn, %{"badge_ids" => ids} -> equip(badges, ids) end)
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/achievements")

    view |> element("#equip-trailblazer") |> render_click()

    assert_received {:api,
                     %{
                       method: "PUT",
                       path: "/api/me/badges/equipped",
                       body: %{"badge_ids" => ["b-sprout-tender", "b-trailblazer"]}
                     }}

    assert has_element?(view, "#slot-2", "Bout du chemin")
    assert has_element?(view, "#equip-status", "Bout du chemin equipped in slot 2.")
    assert has_element?(view, "#unequip-trailblazer")

    view |> element("#slot-2-up") |> render_click()

    assert_received {:api, %{body: %{"badge_ids" => ["b-trailblazer", "b-sprout-tender"]}}}

    assert has_element?(view, "#slot-1", "Bout du chemin")
    assert has_element?(view, "#equip-status", "Bout du chemin moved to slot 1.")

    view |> element("#slot-1-down") |> render_click()
    assert_received {:api, %{body: %{"badge_ids" => ["b-sprout-tender", "b-trailblazer"]}}}

    view |> element("#unequip-trailblazer") |> render_click()
    assert_received {:api, %{body: %{"badge_ids" => ["b-sprout-tender"]}}}
    assert has_element?(view, "#equip-status", "Bout du chemin unequipped.")
    assert has_element?(view, "#slot-2", "Empty")
    refute has_element?(view, "#equip-error .notice")
  end

  test "the limit of three and other refusals are explained, and the state is reloaded", %{
    conn: conn,
    routes: routes
  } do
    badges = catalogue()
    routes = Map.put(routes, {"GET", "/api/me/achievements"}, achievements(badges))

    stub_api(put_equipped(routes, {422, %{"error" => "equip_limit_exceeded"}}))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/achievements")
    assert_received {:api, %{method: "GET", path: "/api/me/achievements"}}

    view |> element("#equip-trailblazer") |> render_click()

    assert has_element?(view, "#equip-error", "Your badges were not changed")
    assert has_element?(view, "#equip-error", "You can equip up to 3 badges.")
    assert_received {:api, %{method: "GET", path: "/api/me/achievements"}}
    assert has_element?(view, "#slot-2", "Empty")

    stub_api(put_equipped(routes, {422, %{"error" => "badge_not_earned"}}))
    view |> element("#equip-trailblazer") |> render_click()
    assert has_element?(view, "#equip-error", "You can only equip badges you have earned.")

    stub_api(put_equipped(routes, :unavailable))
    view |> element("#equip-trailblazer") |> render_click()
    assert has_element?(view, "#equip-error", "temporarily unavailable")
  end

  test "learning unreachable: the page says so instead of failing", %{conn: conn, routes: routes} do
    stub_api(Map.put(routes, {"GET", "/api/me/achievements"}, :unavailable))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/achievements")

    assert has_element?(view, "#achievements-unavailable", "Your badges can't be loaded")
    refute has_element?(view, "#equipped")
  end

  test "members only", %{conn: conn} do
    stub_api(%{{"GET", "/api/sessions/current"} => {401, %{"error" => "unauthorized"}}})

    assert {:error, {:redirect, %{to: "/login?reason=expired&return_to=%2Fachievements"}}} =
             conn |> log_in() |> live(~p"/achievements")
  end
end
