defmodule MlBillingWeb.LocalFlowTest do
  use MlBillingWeb.ConnCase, async: false
  use Oban.Testing, repo: MlBilling.Repo
  alias MlBilling.{CheckoutSession, Invoice, PeriodEndWorker, Subscription, WebhookEvent}

  @urls %{
    "success_url" => "http://localhost:4000/membership/success?session_id={CHECKOUT_SESSION_ID}",
    "cancel_url" => "http://localhost:4000/membership/cancel"
  }

  setup %{conn: conn} do
    user_id = uuid()
    MlShared.Events.subscribe("entitlements")
    MlShared.Events.subscribe(MlShared.Events.user(user_id))
    {:ok, conn: as_user(conn, user_id), user_id: user_id}
  end

  defp checkout(conn, plan),
    do: conn |> post("/api/checkout", Map.put(@urls, "plan", plan)) |> json_response(201)

  defp pay(conn, session_id, outcome \\ "succeeded"),
    do: post(conn, "/api/checkout/#{session_id}/simulate-payment", %{"outcome" => outcome})

  defp paid_subscription(conn, user_id, plan) do
    %{"session_id" => sid} = checkout(conn, plan)
    assert %{"status" => "processing"} = conn |> pay(sid) |> json_response(202)
    assert_receive {:entitlements_changed, ^user_id, ^plan}
    assert_receive {:entitlements_changed, ^user_id, ^plan}
    sid
  end

  defp entitlements(conn, user_id),
    do: conn |> get("/api/entitlements/#{user_id}") |> json_response(200)

  defp end_period_now(user_id) do
    past = DateTime.add(DateTime.utc_now(:second), -60)

    Repo.update_all(from(s in Subscription, where: s.user_id == ^user_id),
      set: [current_period_end: past]
    )
  end

  test "checkout → simulated payment → premium + events; the success URL alone grants nothing", %{
    conn: conn,
    user_id: uid
  } do
    assert %{"url" => url, "session_id" => sid, "mode" => "local"} = checkout(conn, "premium")
    assert url == "/membership/local-checkout/" <> sid

    assert %{"session_id" => ^sid, "plan" => "premium", "status" => "open", "mode" => "local"} =
             conn |> get("/api/checkout/#{sid}") |> json_response(200)

    assert %{"plan" => "free", "status" => "none"} = entitlements(conn, uid)
    refute_received {:entitlements_changed, _, _}

    assert %{"status" => "processing"} = conn |> pay(sid) |> json_response(202)
    # once on "entitlements", once on "user:<id>"
    assert_received {:entitlements_changed, ^uid, "premium"}
    assert_received {:entitlements_changed, ^uid, "premium"}

    assert %{"status" => "completed"} = conn |> get("/api/checkout/#{sid}") |> json_response(200)

    assert %{"plan" => "premium", "status" => "active", "cancel_at_period_end" => false} =
             ent = entitlements(conn, uid)

    {:ok, period_end, 0} = DateTime.from_iso8601(ent["current_period_end"])
    assert DateTime.diff(period_end, DateTime.utc_now(), :day) in 27..31

    assert %{
             "entitlements" => %{"plan" => "premium"},
             "mode" => "local",
             "invoices" => [
               %{
                 "status" => "paid",
                 "amount_cents" => 1200,
                 "currency" => "usd",
                 "hosted_url" => nil
               }
             ]
           } = conn |> get("/api/me/billing") |> json_response(200)

    # every change went through the signed webhook pipeline
    types =
      Repo.all(from e in WebhookEvent, where: e.user_id == ^uid, select: {e.provider, e.type})

    assert Enum.sort(types) == [
             {"local", "checkout.session.completed"},
             {"local", "customer.subscription.created"},
             {"local", "invoice.paid"}
           ]

    # replay: idempotent; same plan again: 409
    assert conn |> pay(sid) |> json_response(202)
    refute_receive {:entitlements_changed, ^uid, _}
    assert Repo.aggregate(Invoice, :count) == 1

    assert %{"error" => "already_subscribed"} =
             conn
             |> post("/api/checkout", Map.put(@urls, "plan", "premium"))
             |> json_response(409)
  end

  test "failed simulated payment: nothing granted, failed invoice, then a successful retry", %{
    conn: conn,
    user_id: uid
  } do
    %{"session_id" => sid} = checkout(conn, "vip")

    assert conn |> pay(sid, "failed") |> json_response(202)
    refute_receive {:entitlements_changed, ^uid, _}
    assert %{"plan" => "free"} = entitlements(conn, uid)
    assert %{"status" => "open"} = conn |> get("/api/checkout/#{sid}") |> json_response(200)

    assert %{"invoices" => [%{"status" => "failed", "amount_cents" => 2400}]} =
             conn |> get("/api/me/billing") |> json_response(200)

    assert conn |> pay(sid) |> json_response(202)
    assert_receive {:entitlements_changed, ^uid, "vip"}

    assert %{"invoices" => [%{"status" => "paid", "amount_cents" => 2400}]} =
             conn |> get("/api/me/billing") |> json_response(200)

    assert %{"error" => "checkout_completed"} = conn |> pay(sid, "failed") |> json_response(409)
  end

  test "IDOR: another user's session is 404, for reading and for paying", %{conn: conn} do
    %{"session_id" => sid} = checkout(conn, "premium")
    other = as_user(build_conn(), uuid())

    assert %{"error" => "not_found"} = other |> get("/api/checkout/#{sid}") |> json_response(404)
    assert %{"error" => "not_found"} = other |> pay(sid) |> json_response(404)

    assert %{"error" => "not_found"} =
             conn |> get("/api/checkout/not-a-uuid") |> json_response(404)

    assert %{"status" => "open"} = conn |> get("/api/checkout/#{sid}") |> json_response(200)
  end

  test "validation (422) and expired session (409)", %{conn: conn} do
    bad = %{"plan" => "gold", "success_url" => "javascript:alert(1)", "cancel_url" => "/relative"}

    assert %{"error" => "invalid", "errors" => errors} =
             conn |> post("/api/checkout", bad) |> json_response(422)

    assert Map.keys(errors) |> Enum.sort() == ["cancel_url", "plan", "success_url"]

    %{"session_id" => sid} = checkout(conn, "premium")

    assert %{"errors" => %{"outcome" => _}} =
             conn
             |> post("/api/checkout/#{sid}/simulate-payment", %{"outcome" => "maybe"})
             |> json_response(422)

    past = DateTime.add(DateTime.utc_now(:second), -1)
    Repo.update_all(from(s in CheckoutSession, where: s.id == ^sid), set: [expires_at: past])
    assert %{"status" => "expired"} = conn |> get("/api/checkout/#{sid}") |> json_response(200)
    assert %{"error" => "checkout_expired"} = conn |> pay(sid) |> json_response(409)
  end

  test "cancel at period end, resume, cancel again; the worker ends it when the period is over",
       %{
         conn: conn,
         user_id: uid
       } do
    assert %{"error" => "not_found"} =
             conn |> post("/api/me/subscription/cancel") |> json_response(404)

    paid_subscription(conn, uid, "premium")

    assert %{"cancel_at_period_end" => true, "plan" => "premium", "status" => "active"} =
             conn |> post("/api/me/subscription/cancel") |> json_response(200)

    assert_receive {:entitlements_changed, ^uid, "premium"}

    assert %{"cancel_at_period_end" => false} =
             conn |> post("/api/me/subscription/resume") |> json_response(200)

    assert %{"cancel_at_period_end" => true} =
             conn |> post("/api/me/subscription/cancel") |> json_response(200)

    # nothing to do before the end of the period
    assert :ok = perform_job(PeriodEndWorker, %{})
    assert %{status: "active"} = Repo.get_by!(Subscription, user_id: uid)

    end_period_now(uid)
    assert %{"plan" => "free", "status" => "active"} = entitlements(conn, uid)
    assert :ok = perform_job(PeriodEndWorker, %{})
    assert_receive {:entitlements_changed, ^uid, "free"}
    assert %{"plan" => "free", "status" => "canceled"} = entitlements(conn, uid)
    assert :ok = perform_job(PeriodEndWorker, %{})

    assert %{"error" => "not_found"} =
             conn |> post("/api/me/subscription/resume") |> json_response(404)

    assert %{"session_id" => _} = checkout(conn, "premium")
  end

  test "an active local subscription is renewed by the worker at period end", %{
    conn: conn,
    user_id: uid
  } do
    paid_subscription(conn, uid, "premium")
    end_period_now(uid)

    assert :ok = perform_job(PeriodEndWorker, %{})
    assert :ok = perform_job(PeriodEndWorker, %{})

    assert %{"plan" => "premium", "status" => "active", "current_period_end" => period_end} =
             entitlements(conn, uid)

    {:ok, period_end, 0} = DateTime.from_iso8601(period_end)
    assert DateTime.after?(period_end, DateTime.add(DateTime.utc_now(), 27, :day))

    assert %{"invoices" => [%{"status" => "paid"}, %{"status" => "paid"}]} =
             conn |> get("/api/me/billing") |> json_response(200)
  end

  test "plan change: a checkout for another plan replaces the subscription once paid", %{
    conn: conn,
    user_id: uid
  } do
    paid_subscription(conn, uid, "premium")
    %{provider_subscription_id: first} = Repo.get_by!(Subscription, user_id: uid)

    %{"session_id" => sid} = checkout(conn, "vip")
    assert %{"plan" => "premium"} = entitlements(conn, uid)

    assert conn |> pay(sid) |> json_response(202)
    assert_receive {:entitlements_changed, ^uid, "vip"}
    assert %{"plan" => "vip", "status" => "active"} = entitlements(conn, uid)

    assert [%Subscription{provider_subscription_id: second}] =
             Repo.all(from s in Subscription, where: s.user_id == ^uid)

    assert second != first
    assert Repo.aggregate(from(i in Invoice, where: i.user_id == ^uid), :count) == 2
  end

  test "the Stripe portal does not exist in local mode", %{conn: conn} do
    assert %{"error" => "not_found"} =
             conn
             |> post("/api/portal", %{"return_url" => "http://localhost:4000/membership"})
             |> json_response(404)
  end
end
