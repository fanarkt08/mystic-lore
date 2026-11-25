defmodule MlBillingWeb.StripeTest do
  use MlBillingWeb.ConnCase, async: false
  alias MlBilling.{CheckoutSession, Signature, WebhookEvent}

  @urls %{
    "success_url" => "http://localhost:4000/membership/success?session_id={CHECKOUT_SESSION_ID}",
    "cancel_url" => "http://localhost:4000/membership/cancel"
  }

  setup {Req.Test, :verify_on_exit!}

  setup %{conn: conn} do
    use_stripe()
    user_id = uuid()
    MlShared.Events.subscribe(MlShared.Events.user(user_id))
    {:ok, conn: as_user(conn, user_id), user_id: user_id}
  end

  defp webhook(raw, header) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    conn = if header, do: put_req_header(conn, "stripe-signature", header), else: conn
    post(conn, "/webhooks/stripe", raw)
  end

  defp webhook(event) do
    {raw, header} = signed(event)
    webhook(raw, header)
  end

  defp form(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {URI.decode_query(body), conn}
  end

  test "checkout: a Stripe Checkout Session in subscription mode; only signed webhooks activate",
       %{
         conn: conn,
         user_id: uid
       } do
    Req.Test.expect(MlBilling.Stripe, fn conn ->
      assert {conn.method, conn.host, conn.request_path} ==
               {"POST", "api.stripe.com", "/v1/checkout/sessions"}

      assert ["Bearer sk_test_fixture"] = get_req_header(conn, "authorization")
      assert ["application/x-www-form-urlencoded"] = get_req_header(conn, "content-type")
      [idempotency_key] = get_req_header(conn, "idempotency-key")
      {form, conn} = form(conn)
      send(self(), {:stripe_form, form, idempotency_key})

      Req.Test.json(conn, %{
        "id" => "cs_test_123",
        "url" => "https://checkout.stripe.com/c/pay/cs_test_123"
      })
    end)

    assert %{
             "url" => "https://checkout.stripe.com/c/pay/cs_test_123",
             "session_id" => sid,
             "mode" => "stripe"
           } =
             conn
             |> post("/api/checkout", Map.put(@urls, "plan", "premium"))
             |> json_response(201)

    assert_received {:stripe_form, form, ^sid}

    assert %{
             "mode" => "subscription",
             "line_items[0][price]" => "price_premium_fx",
             "line_items[0][quantity]" => "1",
             "client_reference_id" => ^uid,
             "metadata[user_id]" => ^uid,
             "metadata[plan]" => "premium",
             "subscription_data[metadata][user_id]" => ^uid,
             "subscription_data[metadata][plan]" => "premium",
             "cancel_url" => "http://localhost:4000/membership/cancel"
           } = form

    assert form["success_url"] == "http://localhost:4000/membership/success?session_id=" <> sid
    refute Map.has_key?(form, "customer")
    assert %CheckoutSession{provider_session_id: "cs_test_123"} = Repo.get!(CheckoutSession, sid)

    # signed checkout.session.completed: session completed, still no entitlement
    completed = %{
      "id" => "cs_test_123",
      "object" => "checkout.session",
      "client_reference_id" => uid,
      "customer" => "cus_test_1",
      "subscription" => "sub_test_1",
      "customer_details" => %{"email" => "someone@example.test", "name" => "Someone"}
    }

    assert %{"status" => "processed"} =
             webhook(event("checkout.session.completed", completed)) |> json_response(200)

    assert %{"status" => "completed"} = conn |> get("/api/checkout/#{sid}") |> json_response(200)
    assert MlBilling.entitlements(uid).plan == "free"

    stored = Repo.get_by!(WebhookEvent, type: "checkout.session.completed").payload
    refute Map.has_key?(stored["data"]["object"], "customer_details")

    # signed customer.subscription.created: premium
    assert %{"status" => "processed"} =
             webhook(event("customer.subscription.created", stripe_subscription(uid)))
             |> json_response(200)

    assert_receive {:entitlements_changed, ^uid, "premium"}

    assert %{"plan" => "premium", "status" => "active"} =
             conn |> get("/api/entitlements/#{uid}") |> json_response(200)

    # a later checkout (other plan) reuses the Stripe customer
    Req.Test.expect(MlBilling.Stripe, fn conn ->
      {form, conn} = form(conn)
      assert %{"customer" => "cus_test_1", "line_items[0][price]" => "price_vip_fx"} = form

      Req.Test.json(conn, %{
        "id" => "cs_test_456",
        "url" => "https://checkout.stripe.com/c/pay/cs_test_456"
      })
    end)

    assert %{"mode" => "stripe"} =
             conn |> post("/api/checkout", Map.put(@urls, "plan", "vip")) |> json_response(201)
  end

  test "the webhook answers 400 to invalid, expired or missing signatures", %{user_id: uid} do
    {raw, _header} = signed(event("customer.subscription.created", stripe_subscription(uid)))
    expired = Signature.header(raw, "whsec_test_fixture", System.os_time(:second) - 301)

    for header <- [Signature.header(raw, "whsec_wrong"), expired, "t=1,v1=00", nil] do
      assert %{"error" => "invalid_signature"} = raw |> webhook(header) |> json_response(400)
    end

    assert MlBilling.entitlements(uid).plan == "free"
    assert Repo.aggregate(WebhookEvent, :count) == 0
  end

  test "unhandled event types are acknowledged (200) and ignored; a redelivery is a duplicate" do
    event = event("payment_intent.succeeded", %{"id" => "pi_1"})
    assert %{"status" => "ignored"} = event |> webhook() |> json_response(200)
    assert %{"status" => "duplicate"} = event |> webhook() |> json_response(200)
  end

  test "portal, cancel and resume go through the Stripe API", %{conn: conn, user_id: uid} do
    webhook(event("customer.subscription.created", stripe_subscription(uid)))

    Req.Test.expect(MlBilling.Stripe, fn conn ->
      assert conn.request_path == "/v1/billing_portal/sessions"
      {form, conn} = form(conn)

      assert form == %{
               "customer" => "cus_test_1",
               "return_url" => "http://localhost:4000/membership"
             }

      Req.Test.json(conn, %{"url" => "https://billing.stripe.com/p/session/test_1"})
    end)

    assert %{"url" => "https://billing.stripe.com/p/session/test_1"} =
             conn
             |> post("/api/portal", %{"return_url" => "http://localhost:4000/membership"})
             |> json_response(201)

    assert %{"errors" => %{"return_url" => _}} =
             conn |> post("/api/portal", %{"return_url" => "nope"}) |> json_response(422)

    for flag <- [true, false] do
      Req.Test.expect(MlBilling.Stripe, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/v1/subscriptions/sub_test_1"}
        {form, conn} = form(conn)
        assert form == %{"cancel_at_period_end" => to_string(flag)}

        Req.Test.json(conn, %{
          "id" => "sub_test_1",
          "status" => "active",
          "cancel_at_period_end" => flag
        })
      end)

      path = if flag, do: "/api/me/subscription/cancel", else: "/api/me/subscription/resume"

      assert %{"cancel_at_period_end" => ^flag, "plan" => "premium"} =
               conn |> post(path) |> json_response(200)
    end

    Req.Test.expect(MlBilling.Stripe, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"type" => "api_error"}})
    end)

    assert %{"error" => "provider_error"} =
             conn |> post("/api/me/subscription/cancel") |> json_response(502)

    assert %{cancel_at_period_end: false} = MlBilling.entitlements(uid)
  end

  test "provider failure on checkout → 502, nothing stored; no simulated payment in Stripe mode",
       %{
         conn: conn
       } do
    Req.Test.expect(MlBilling.Stripe, &Req.Test.transport_error(&1, :econnrefused))

    assert %{"error" => "provider_error"} =
             conn
             |> post("/api/checkout", Map.put(@urls, "plan", "premium"))
             |> json_response(502)

    assert Repo.aggregate(CheckoutSession, :count) == 0

    assert %{"error" => "not_found"} =
             conn
             |> post("/api/checkout/#{uuid()}/simulate-payment", %{"outcome" => "succeeded"})
             |> json_response(404)
  end
end
