defmodule MlBillingWeb.PrivacyTest do
  use MlBillingWeb.ConnCase, async: false
  import Ecto.Query, only: [from: 2]

  alias MlBilling.{
    CheckoutSession,
    CreditEntry,
    Credits,
    Invoice,
    Repo,
    Subscription,
    WebhookEvent
  }

  setup {Req.Test, :verify_on_exit!}

  defp caller(service, user_id \\ nil) do
    put_req_header(
      build_conn(),
      "authorization",
      "Bearer " <> MlShared.InternalToken.sign(service, user_id)
    )
  end

  defp subscribed!(user_id, provider, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %Subscription{
          user_id: user_id,
          plan: "premium",
          status: "active",
          provider: provider,
          provider_customer_id: "cus_#{provider}_1",
          provider_subscription_id: "sub_#{provider}_1",
          current_period_start: now,
          current_period_end: DateTime.add(now, 30 * 86_400),
          last_event_at: DateTime.add(now, -60)
        },
        attrs
      )
    )
  end

  defp billed!(user_id) do
    Repo.insert!(%Invoice{
      user_id: user_id,
      provider: "local",
      provider_invoice_id: "in_#{System.unique_integer([:positive])}",
      amount_cents: 1200,
      currency: "usd",
      status: "paid",
      hosted_url: "https://invoice.example/secret-link"
    })

    Repo.insert!(%WebhookEvent{
      provider: "stripe",
      provider_event_id: "evt_#{System.unique_integer([:positive])}",
      type: "invoice.paid",
      event_created_at: DateTime.utc_now(:second),
      user_id: user_id,
      status: "processed",
      payload: %{"customer_email" => "lea@example.test", "customer_name" => "Léa Moreau"}
    })

    {:ok, _} = Credits.reserve(user_id, 2, "studio:gen:#{uuid()}", "outline")
  end

  setup do
    [me, other] = for _ <- 1..2, do: uuid()
    billed!(me)
    billed!(other)
    %{me: me, other: other}
  end

  test "only the accounts service may call them (403 otherwise)", %{me: me} do
    for conn <- [caller("web", me), caller("studio"), caller("learning")] do
      assert %{"error" => "forbidden"} =
               conn |> get("/api/internal/users/#{me}/export") |> json_response(403)

      assert conn |> recycle() |> delete("/api/internal/users/#{me}") |> json_response(403)
    end
  end

  test "export: subscription, invoices and credit ledger of this member only", %{me: me} do
    subscribed!(me, "local")

    assert %{"data" => data} =
             caller("accounts") |> get("/api/internal/users/#{me}/export") |> json_response(200)

    assert %{"plan" => "premium", "status" => "active", "provider" => "local"} =
             data["subscription"]

    assert %{"plan" => "premium"} = data["entitlements"]
    assert [%{"amount_cents" => 1200, "status" => "paid"}] = data["invoices"]

    assert ["allocation", "reservation"] = Enum.map(data["credits"]["ledger"], & &1["kind"])
    assert %{"reserved" => 2} = data["credits"]["account"]
    assert caller("accounts") |> get("/api/internal/users/x/export") |> json_response(404)
  end

  test "DELETE (local): subscription ended at once, invoices and ledger kept without personal data",
       %{me: me, other: other} do
    subscribed!(me, "local")
    MlShared.Events.subscribe("entitlements")

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
    assert_receive {:entitlements_changed, ^me, "free"}

    assert %Subscription{status: "canceled", cancel_at_period_end: false} =
             Repo.get_by!(Subscription, user_id: me)

    assert %{plan: "free", status: "canceled"} = MlBilling.entitlements(me)

    # conservés (obligation comptable), sans donnée personnelle
    assert [%Invoice{amount_cents: 1200, hosted_url: nil}] =
             Repo.all(from i in Invoice, where: i.user_id == ^me)

    assert [%WebhookEvent{payload: %{}, type: "invoice.paid"}] =
             Repo.all(from w in WebhookEvent, where: w.user_id == ^me)

    assert Repo.aggregate(from(e in CreditEntry, where: e.user_id == ^me), :count) == 2

    # l'autre membre n'est pas touché
    assert [%Invoice{hosted_url: "https://" <> _}] =
             Repo.all(from i in Invoice, where: i.user_id == ^other)

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
  end

  test "DELETE (Stripe): cancellation and open checkout expired at Stripe", %{me: me} do
    use_stripe()
    subscribed!(me, "stripe", %{provider_subscription_id: "sub_live1"})

    Repo.insert!(%CheckoutSession{
      id: uuid(),
      user_id: me,
      plan: "vip",
      provider: "stripe",
      provider_session_id: "cs_test_open1",
      expires_at: DateTime.add(DateTime.utc_now(:second), 1800)
    })

    test = self()

    Req.Test.expect(MlBilling.Stripe, 2, fn conn ->
      send(test, {:stripe, conn.method, conn.request_path})
      Req.Test.json(conn, %{"id" => "ok", "status" => "canceled"})
    end)

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
    assert_received {:stripe, "POST", "/v1/checkout/sessions/cs_test_open1/expire"}
    assert_received {:stripe, "DELETE", "/v1/subscriptions/sub_live1"}
    assert %Subscription{status: "canceled"} = Repo.get_by!(Subscription, user_id: me)

    assert [%CheckoutSession{} = session] =
             Repo.all(from s in CheckoutSession, where: s.user_id == ^me)

    assert CheckoutSession.status(session) == "expired"
  end

  test "DELETE (Stripe unreachable): 503, the subscription is left untouched", %{me: me} do
    use_stripe()
    subscribed!(me, "stripe", %{provider_subscription_id: "sub_live2"})
    Req.Test.expect(MlBilling.Stripe, &Req.Test.transport_error(&1, :econnrefused))

    assert %{"error" => "provider_error"} =
             caller("accounts") |> delete("/api/internal/users/#{me}") |> json_response(503)

    assert %Subscription{status: "active"} = Repo.get_by!(Subscription, user_id: me)
  end
end
