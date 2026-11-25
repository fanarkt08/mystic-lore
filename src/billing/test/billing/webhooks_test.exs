defmodule MlBilling.WebhooksTest do
  use MlBilling.DataCase, async: false
  use Oban.Testing, repo: MlBilling.Repo
  alias MlBilling.{Invoice, Local, Signature, Subscription, WebhookEvent, Webhooks}

  setup do
    use_stripe()
    user_id = uuid()
    MlShared.Events.subscribe("entitlements")
    {:ok, user_id: user_id}
  end

  defp deliver(event) do
    {raw, header} = signed(event)
    Webhooks.handle("stripe", raw, header)
  end

  defp subscription(user_id), do: Repo.get_by!(Subscription, user_id: user_id)

  test "an event is applied once: the same event again is a duplicate", %{user_id: uid} do
    event = event("customer.subscription.created", stripe_subscription(uid), id: "evt_twice")

    assert {:ok, "processed"} = deliver(event)
    assert_receive {:entitlements_changed, ^uid, "premium"}
    assert {:ok, "duplicate"} = deliver(event)
    refute_receive {:entitlements_changed, ^uid, _}

    assert Repo.aggregate(
             from(e in WebhookEvent, where: e.provider_event_id == "evt_twice"),
             :count
           ) ==
             1

    assert %{plan: "premium", status: "active", cancel_at_period_end: false} =
             MlBilling.entitlements(uid)
  end

  test "a bad signature, an expired one or the other provider's secret changes nothing", %{
    user_id: uid
  } do
    raw = Jason.encode!(event("customer.subscription.created", stripe_subscription(uid)))
    old = System.os_time(:second) - 301

    assert {:error, :invalid_signature} =
             Webhooks.handle("stripe", raw, Signature.header(raw, "whsec_wrong"))

    assert {:error, :expired_signature} =
             Webhooks.handle("stripe", raw, Signature.header(raw, "whsec_test_fixture", old))

    assert {:error, :invalid_signature} =
             Webhooks.handle("stripe", raw, Signature.header(raw, Local.secret()))

    assert {:error, :invalid_signature} =
             Webhooks.handle("local", raw, Signature.header(raw, "whsec_test_fixture"))

    assert {:error, :invalid_signature} = Webhooks.handle("stripe", raw, nil)
    assert Repo.aggregate(WebhookEvent, :count) == 0
    assert MlBilling.entitlements(uid).plan == "free"
  end

  test "an event older than the last applied one is recorded but ignored", %{user_id: uid} do
    now = System.os_time(:second)
    newer = stripe_subscription(uid, cancel_at_period_end: true)

    assert {:ok, "processed"} =
             deliver(event("customer.subscription.updated", newer, created: now))

    assert {:ok, "stale"} =
             deliver(
               event("customer.subscription.created", stripe_subscription(uid),
                 id: "evt_old",
                 created: now - 60
               )
             )

    assert %{cancel_at_period_end: true, last_event_at: last} = subscription(uid)
    assert DateTime.to_unix(last) == now

    assert %{status: "stale", user_id: ^uid} =
             Repo.get_by!(WebhookEvent, provider_event_id: "evt_old")
  end

  test "unknown types are ignored; unknown users or prices fail without effect", %{user_id: uid} do
    assert {:ok, "ignored"} = deliver(event("customer.created", %{"id" => "cus_new"}))

    orphan = Map.delete(stripe_subscription(uid, customer: "cus_unknown"), "metadata")
    assert {:ok, "failed"} = deliver(event("customer.subscription.created", orphan, id: "evt_o"))
    assert %{error: "unknown_user"} = Repo.get_by!(WebhookEvent, provider_event_id: "evt_o")

    unknown_price = stripe_subscription(uid, price: "price_elsewhere")
    assert {:ok, "failed"} = deliver(event("customer.subscription.created", unknown_price))
    assert MlBilling.entitlements(uid).plan == "free"
  end

  test "payment failure: past_due with a 3-day grace, recovered by invoice.paid", %{user_id: uid} do
    now = System.os_time(:second)
    deliver(event("customer.subscription.created", stripe_subscription(uid), created: now - 10))

    assert {:ok, "processed"} =
             deliver(event("invoice.payment_failed", stripe_invoice(), created: now - 5))

    assert %{status: "past_due", past_due_since: %DateTime{}} = subscription(uid)
    assert %{plan: "premium", status: "past_due"} = MlBilling.entitlements(uid)
    assert MlBilling.entitlements(uid, DateTime.add(DateTime.utc_now(), 4, :day)).plan == "free"

    assert %{status: "failed", amount_cents: 1200} =
             Repo.get_by!(Invoice, provider_invoice_id: "in_test_1")

    paid = stripe_invoice(status: "paid", amount_paid: 1200)
    assert {:ok, "processed"} = deliver(event("invoice.paid", paid, created: now))
    assert %{status: "active", past_due_since: nil} = subscription(uid)

    # a late failure of the now paid invoice changes nothing
    assert {:ok, "stale"} =
             deliver(event("invoice.payment_failed", stripe_invoice(), created: now))

    assert %{status: "paid", amount_cents: 1200, hosted_url: "https://invoice.stripe.com/" <> _} =
             Repo.get_by!(Invoice, provider_invoice_id: "in_test_1")

    assert %{status: "active"} = subscription(uid)
  end

  test "subscription deleted → canceled and free", %{user_id: uid} do
    deliver(event("customer.subscription.created", stripe_subscription(uid)))
    assert_receive {:entitlements_changed, ^uid, "premium"}

    deleted = stripe_subscription(uid, status: "canceled")
    assert {:ok, "processed"} = deliver(event("customer.subscription.deleted", deleted))
    assert_receive {:entitlements_changed, ^uid, "free"}
    assert %{plan: "free", status: "canceled"} = MlBilling.entitlements(uid)
  end

  test "a newer ACTIVE subscription replaces the current one; the old one is canceled at Stripe",
       %{user_id: uid} do
    now = System.os_time(:second)
    old = stripe_subscription(uid, id: "sub_old")
    deliver(event("customer.subscription.created", old, created: now - 10))

    incomplete =
      stripe_subscription(uid, id: "sub_new", status: "incomplete", price: "price_vip_fx")

    assert {:ok, "ignored"} =
             deliver(event("customer.subscription.created", incomplete, created: now - 5))

    assert %{provider_subscription_id: "sub_old", plan: "premium"} = subscription(uid)

    active = stripe_subscription(uid, id: "sub_new", price: "price_vip_fx")

    assert {:ok, "processed"} =
             deliver(event("customer.subscription.updated", active, created: now))

    assert %{provider_subscription_id: "sub_new", plan: "vip", status: "active"} =
             subscription(uid)

    assert_enqueued(worker: MlBilling.StripeCancelWorker, args: %{"subscription_id" => "sub_old"})

    # the deletion of the replaced subscription does not touch the new one
    deleted_old = stripe_subscription(uid, id: "sub_old", status: "canceled")
    assert {:ok, "ignored"} = deliver(event("customer.subscription.deleted", deleted_old))
    assert MlBilling.entitlements(uid).plan == "vip"

    Req.Test.expect(MlBilling.Stripe, fn conn ->
      assert {conn.method, conn.request_path, conn.query_string} ==
               {"DELETE", "/v1/subscriptions/sub_old", "prorate=true"}

      Req.Test.json(conn, %{"id" => "sub_old", "status" => "canceled"})
    end)

    assert :ok = perform_job(MlBilling.StripeCancelWorker, %{"subscription_id" => "sub_old"})

    Req.Test.expect(MlBilling.Stripe, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"error" => %{"code" => "resource_missing"}})
    end)

    assert {:cancel, _} =
             perform_job(MlBilling.StripeCancelWorker, %{"subscription_id" => "sub_old"})
  end
end
