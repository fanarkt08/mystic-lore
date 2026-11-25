defmodule MysticWeb.HomeLiveTest do
  use MysticWeb.ConnCase, async: true

  test "presents the academy with adventures (learning) and plans (billing)", %{conn: conn} do
    stub_api(%{
      {"GET", "/api/adventures"} =>
        page([
          adventure(),
          adventure(%{
            "slug" => "celestial-atlas",
            "title" => "L'Atlas céleste",
            "premium" => true
          })
        ]),
      {"GET", "/api/plans"} => plans("local")
    })

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#home-adventure-la-foret-des-murmures a[href='/adventures/la-foret-des-murmures']"
           )

    assert has_element?(view, "#home-adventure-celestial-atlas", "Premium")
    assert has_element?(view, "#plan-premium", "$12")
    assert has_element?(view, "#payment-mode", "Demo payment mode — no real money")
    assert has_element?(view, "#faq")

    # mention discrète et honnête dans le pied de page ; illustrations réelles (WebP locaux), sans libellé provisoire
    assert html =~ "Demo project — all members, adventures and payments are fictional."
    assert html =~ ~s(src="/images/art/hero.webp")
    assert html =~ ~s(src="/images/art/forest.webp")
    refute html =~ "Placeholder art"
  end

  test "each zone degrades on its own when a service is unreachable", %{conn: conn} do
    stub_api(%{
      {"GET", "/api/adventures"} => :unavailable,
      {"GET", "/api/plans"} => plans("disabled")
    })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#adventures-unavailable", "Temporarily unavailable")
    assert has_element?(view, "#payment-mode", "Payments not configured")
    assert has_element?(view, "#plan-vip")
  end

  test "signed-in members get the application rail", %{conn: conn} do
    user = user_fixture()

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/adventures"} => page([]),
        {"GET", "/api/plans"} => :unavailable
      })
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/")

    assert has_element?(view, "#nav-dashboard")
    assert has_element?(view, "#plans-unavailable")
  end
end
