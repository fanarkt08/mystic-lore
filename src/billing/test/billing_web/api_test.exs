defmodule MlBillingWeb.ApiTest do
  use MlBillingWeb.ConnCase, async: false

  test "GET /healthz needs no token", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/healthz") |> json_response(200)
  end

  test "/api requires an internal token, and a user for user routes", %{conn: conn} do
    assert %{"error" => "unauthorized"} = conn |> get("/api/plans") |> json_response(401)

    forged = put_req_header(conn, "authorization", "Bearer forged")
    assert %{"error" => "unauthorized"} = forged |> get("/api/plans") |> json_response(401)

    service = as_user(conn, nil)
    assert %{"plans" => _} = service |> get("/api/plans") |> json_response(200)
    assert %{"error" => "unauthorized"} = service |> get("/api/me/billing") |> json_response(401)

    assert %{"error" => "unauthorized"} =
             service |> post("/api/checkout", %{}) |> json_response(401)
  end

  test "GET /api/plans: the 3 demo plans and the mode", %{conn: conn} do
    assert %{"mode" => "local", "plans" => [free, premium, vip]} =
             conn |> as_user(nil) |> get("/api/plans") |> json_response(200)

    assert %{
             "key" => "free",
             "name" => "Free",
             "price_cents" => 0,
             "currency" => "usd",
             "interval" => "month"
           } =
             free

    assert %{"key" => "premium", "price_cents" => 1200} = premium
    assert %{"key" => "vip", "price_cents" => 2400, "features" => [_ | _]} = vip
  end

  test "GET /api/entitlements/:user_id: free without subscription, 404 for a malformed id", %{
    conn: conn
  } do
    id = uuid()

    assert %{
             "user_id" => ^id,
             "plan" => "free",
             "status" => "none",
             "current_period_end" => nil,
             "cancel_at_period_end" => false
           } = conn |> as_user(nil) |> get("/api/entitlements/#{id}") |> json_response(200)

    assert %{"error" => "not_found"} =
             conn |> as_user(nil) |> get("/api/entitlements/nope") |> json_response(404)
  end

  test "GET /api/me/billing without subscription", %{conn: conn} do
    assert %{"entitlements" => %{"plan" => "free"}, "invoices" => [], "mode" => "local"} =
             conn |> as_user(uuid()) |> get("/api/me/billing") |> json_response(200)
  end

  test "disabled mode (BILLING_LOCAL_MODE=false): honest 503 / 404", %{conn: conn} do
    put_billing_env(:local_mode, "false")
    conn = as_user(conn, uuid())

    body = %{
      "plan" => "premium",
      "success_url" => "http://x.test/s",
      "cancel_url" => "http://x.test/c"
    }

    assert %{"mode" => "disabled"} = conn |> get("/api/plans") |> json_response(200)

    assert %{"error" => "payments_disabled"} =
             conn |> post("/api/checkout", body) |> json_response(503)

    assert %{"error" => "not_found"} =
             conn
             |> post("/api/checkout/#{uuid()}/simulate-payment", %{"outcome" => "succeeded"})
             |> json_response(404)
  end

  test "production: local mode refused unless BILLING_LOCAL_MODE=true, Stripe allowed" do
    put_billing_env(:env, :prod)
    put_billing_env(:local_mode, nil)
    assert MlBilling.mode() == :disabled

    put_billing_env(:local_mode, "true")
    assert MlBilling.mode() == :local

    use_stripe()
    assert MlBilling.mode() == :stripe

    use_stripe(price_vip: "")
    assert MlBilling.mode() == :local
  end

  test "unknown routes answer a JSON 404", %{conn: conn} do
    assert %{"error" => "not_found"} = conn |> get("/nope") |> json_response(404)
  end
end
