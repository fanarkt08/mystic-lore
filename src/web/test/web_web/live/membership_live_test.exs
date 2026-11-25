defmodule MysticWeb.MembershipLiveTest do
  use MysticWeb.ConnCase, async: true

  defp start(conn, user, routes) do
    stub_api(Map.merge(member_routes(user), routes))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/membership")
    view
  end

  test "compares plans and shows the current plan in demo payment mode", %{conn: conn} do
    user = user_fixture()

    invoice = %{
      "id" => "in_1",
      "amount_cents" => 1200,
      "currency" => "usd",
      "status" => "paid",
      "period_start" => "2026-10-23T00:00:00Z",
      "period_end" => "2026-11-23T00:00:00Z",
      "hosted_url" => nil
    }

    view =
      start(conn, user, %{
        {"GET", "/api/plans"} => plans("local"),
        {"GET", "/api/me/billing"} => %{billing(user["id"]) | "invoices" => [invoice]}
      })

    assert has_element?(view, "#payment-mode", "Demo payment mode — no real money")
    assert has_element?(view, "#plan-free", "Current plan")
    assert has_element?(view, "#checkout-premium", "Subscribe")
    assert has_element?(view, "#invoice-in_1", "$12")
    assert has_element?(view, "#invoice-in_1", "Paid")
  end

  test "local checkout: absolute return URLs, then the demo payment page", %{conn: conn} do
    user = user_fixture()

    view =
      start(conn, user, %{
        {"GET", "/api/plans"} => plans("local"),
        {"GET", "/api/me/billing"} => billing(user["id"]),
        {"POST", "/api/checkout"} =>
          {201,
           %{
             "url" => "/membership/local-checkout/cs_1",
             "session_id" => "cs_1",
             "mode" => "local"
           }}
      })

    view |> element("#checkout-premium") |> render_click()

    assert_redirect(view, "/membership/local-checkout/cs_1")
    assert_received {:api, %{method: "POST", path: "/api/checkout", body: body}}
    assert body["plan"] == "premium"

    assert body["success_url"] ==
             "http://localhost:4000/membership/success?session_id={CHECKOUT_SESSION_ID}"

    assert body["cancel_url"] == "http://localhost:4000/membership/cancel"
  end

  test "stripe checkout and billing portal are external redirects", %{conn: conn} do
    user = user_fixture()

    view =
      start(conn, user, %{
        {"GET", "/api/plans"} => plans("stripe"),
        {"GET", "/api/me/billing"} =>
          billing(
            user["id"],
            %{
              "plan" => "premium",
              "status" => "active",
              "current_period_end" => "2026-12-23T00:00:00Z"
            },
            "stripe"
          ),
        {"POST", "/api/checkout"} =>
          {201,
           %{
             "url" => "https://checkout.stripe.com/c/pay/cs_test_1",
             "session_id" => "cs_test_1",
             "mode" => "stripe"
           }},
        {"POST", "/api/portal"} =>
          {201, %{"url" => "https://billing.stripe.com/p/session/test_1"}}
      })

    assert has_element?(view, "#plan-premium", "Current plan")
    assert has_element?(view, "#period-end", "Renews on Dec 23, 2026")

    assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/pay/cs_test_1"}}} =
             view |> element("#checkout-vip") |> render_click()

    {:ok, view, _html} = conn |> log_in() |> live(~p"/membership")

    assert {:error, {:redirect, %{to: "https://billing.stripe.com/p/session/test_1"}}} =
             view |> element("#billing-portal") |> render_click()

    assert_received {:api,
                     %{
                       path: "/api/portal",
                       body: %{"return_url" => "http://localhost:4000/membership"}
                     }}
  end

  test "cancel at period end, resume, and refusal messages", %{conn: conn} do
    user = user_fixture()

    active = %{
      "plan" => "premium",
      "status" => "active",
      "current_period_end" => "2026-12-23T00:00:00Z"
    }

    ent = billing(user["id"], active)["entitlements"]

    view =
      start(conn, user, %{
        {"GET", "/api/plans"} => plans("local"),
        {"GET", "/api/me/billing"} => billing(user["id"], active),
        {"POST", "/api/me/subscription/cancel"} => %{ent | "cancel_at_period_end" => true},
        {"POST", "/api/me/subscription/resume"} => ent,
        {"POST", "/api/checkout"} => {409, %{"error" => "already_subscribed"}}
      })

    view |> element("#cancel-subscription") |> render_click()
    assert has_element?(view, "#period-end", "Ends on Dec 23, 2026")
    assert has_element?(view, "#resume-subscription")

    view |> element("#resume-subscription") |> render_click()
    assert has_element?(view, "#cancel-subscription")

    view |> element("#checkout-vip") |> render_click()
    assert render(view) =~ "You already have this plan."
  end

  test "payments disabled: no checkout button", %{conn: conn} do
    user = user_fixture()

    view =
      start(conn, user, %{
        {"GET", "/api/plans"} => plans("disabled"),
        {"GET", "/api/me/billing"} => billing(user["id"], %{}, "disabled")
      })

    assert has_element?(view, "#payment-mode", "Payments not configured")
    refute has_element?(view, "#checkout-premium")
  end

  test "reloads the subscription on entitlements_changed", %{conn: conn} do
    user = user_fixture()

    routes = %{
      {"GET", "/api/plans"} => plans("local"),
      {"GET", "/api/me/billing"} => billing(user["id"])
    }

    view = start(conn, user, routes)
    assert has_element?(view, "#plan-free", "Current plan")

    stub_api(
      Map.merge(member_routes(user), %{
        routes
        | {"GET", "/api/me/billing"} =>
            billing(user["id"], %{"plan" => "vip", "status" => "active"})
      })
    )

    MlShared.Events.broadcast("user:#{user["id"]}", {:entitlements_changed, user["id"], "vip"})

    assert render(view) =~ "This is your plan."
    assert has_element?(view, "#plan-vip", "Current plan")
  end

  test "billing unreachable", %{conn: conn} do
    user = user_fixture()

    view =
      start(conn, user, %{
        {"GET", "/api/plans"} => :unavailable,
        {"GET", "/api/me/billing"} => :unavailable
      })

    assert has_element?(view, "#current-plan", "Temporarily unavailable")
  end
end
