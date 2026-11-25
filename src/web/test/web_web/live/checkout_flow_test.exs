defmodule MysticWeb.CheckoutFlowTest do
  use MysticWeb.ConnCase, async: true

  defp checkout(status),
    do: %{"session_id" => "cs_1", "plan" => "premium", "status" => status, "mode" => "local"}

  test "demo payment → waiting → activated only by billing's event", %{conn: conn} do
    user = user_fixture()

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/checkout/cs_1"} => checkout("open"),
        {"GET", "/api/plans"} => plans("local"),
        {"GET", "/api/me/billing"} => billing(user["id"]),
        {"POST", "/api/checkout/cs_1/simulate-payment"} => {202, %{"status" => "processing"}}
      })

    stub_api(routes)
    conn = log_in(conn)

    {:ok, pay, _html} = live(conn, ~p"/membership/local-checkout/cs_1")
    assert has_element?(pay, "#demo-checkout", "DEMO — simulated payment, no real money")
    assert has_element?(pay, "#demo-checkout", "$12")

    pay |> element("#pay") |> render_click()
    assert_redirect(pay, "/membership/success?session_id=cs_1")

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/checkout/cs_1/simulate-payment",
                       body: %{"outcome" => "succeeded"}
                     }}

    {:ok, success, _html} = live(conn, ~p"/membership/success?session_id=cs_1")
    assert has_element?(success, "#payment-status", "Waiting for payment confirmation…")

    # Billing processed the signed (simulated) webhook: session completed, plan granted, event published.
    stub_api(%{
      routes
      | {"GET", "/api/checkout/cs_1"} => checkout("completed"),
        {"GET", "/api/me/billing"} =>
          billing(user["id"], %{"plan" => "premium", "status" => "active"})
    })

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:entitlements_changed, user["id"], "premium"}
    )

    assert render(success) =~ "Welcome to Premium"
  end

  test "the status page never unlocks anything itself", %{conn: conn} do
    user = user_fixture()

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/checkout/cs_1"} => checkout("completed"),
        {"GET", "/api/me/billing"} => billing(user["id"])
      })
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/membership/success?session_id=cs_1")

    # Completed session but billing still reports the free plan: keep waiting, write nothing.
    assert has_element?(view, "#payment-status", "Waiting for payment confirmation…")
    view |> element("#check-again") |> render_click()
    refute_received {:api, %{method: "POST"}}
  end

  test "a simulated failure stays on the demo page (session still open)", %{conn: conn} do
    user = user_fixture()

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/checkout/cs_1"} => checkout("open"),
        {"GET", "/api/plans"} => plans("local"),
        {"POST", "/api/checkout/cs_1/simulate-payment"} => {202, %{"status" => "processing"}}
      })
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/membership/local-checkout/cs_1")
    view |> element("#simulate-failure") |> render_click()

    assert_received {:api,
                     %{
                       path: "/api/checkout/cs_1/simulate-payment",
                       body: %{"outcome" => "failed"}
                     }}

    assert has_element?(view, "#payment-failed", "Nothing was charged")
    assert has_element?(view, "#pay")
  end

  test "expired sessions and foreign sessions", %{conn: conn} do
    user = user_fixture()

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/checkout/cs_old"} => %{checkout("expired") | "session_id" => "cs_old"},
        {"GET", "/api/checkout/cs_other"} => {404, %{"error" => "not_found"}},
        {"GET", "/api/me/billing"} => billing(user["id"]),
        {"GET", "/api/plans"} => plans("local")
      })
    )

    conn = log_in(conn)
    {:ok, view, _html} = live(conn, ~p"/membership/success?session_id=cs_old")
    assert has_element?(view, "#payment-status", "Payment not completed")

    {:ok, view, _html} = live(conn, ~p"/membership/local-checkout/cs_other")
    assert has_element?(view, "#checkout-not-found")

    {:ok, view, _html} = live(conn, ~p"/membership/local-checkout/cs_old")
    assert has_element?(view, "#checkout-closed")
  end

  test "canceled checkout page", %{conn: conn} do
    stub_api(member_routes(user_fixture()))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/membership/cancel")
    assert has_element?(view, "#checkout-canceled", "No payment was made")
  end
end
