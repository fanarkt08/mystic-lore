defmodule MlBilling.NoticesTest do
  @moduledoc """
  Producteur `billing` : chaque changement d'abonnement appliqué par le pipeline des webhooks met en file une
  notification durable, dans la transaction ; un webhook rejoué n'en crée pas d'autre.
  """
  use MlBilling.DataCase, async: false
  use Oban.Testing, repo: MlBilling.Repo
  alias MlBilling.{NotifyWorker, Webhooks}

  setup do
    use_stripe()
    {:ok, user_id: uuid()}
  end

  defp deliver(event) do
    {raw, header} = signed(event)
    Webhooks.handle("stripe", raw, header)
  end

  defp notices(user_id) do
    for job <- Enum.sort_by(all_enqueued(worker: NotifyWorker), & &1.id),
        job.args["user_id"] == user_id,
        do: {job.args["kind"], job.args["params"]}
  end

  test "Stripe (test mode): activation, payment failure, scheduled cancellation, end", %{
    user_id: uid
  } do
    created = event("customer.subscription.created", stripe_subscription(uid), id: "evt_n1")
    assert {:ok, "processed"} = deliver(created)
    assert [{"subscription_activated", %{"plan" => "premium"}}] = notices(uid)

    # the same event again: nothing more
    assert {:ok, "duplicate"} = deliver(created)
    assert length(notices(uid)) == 1

    assert {:ok, "processed"} =
             deliver(event("invoice.payment_failed", stripe_invoice(), id: "evt_n2"))

    assert {"payment_failed", %{"plan" => "premium"}} in notices(uid)

    assert {:ok, "processed"} =
             deliver(
               event(
                 "customer.subscription.updated",
                 stripe_subscription(uid, status: "active", cancel_at_period_end: true),
                 id: "evt_n3"
               )
             )

    assert [{"cancellation_scheduled", %{"plan" => "premium", "period_end" => end_at}}] =
             Enum.filter(notices(uid), &(elem(&1, 0) == "cancellation_scheduled"))

    assert is_binary(end_at)

    assert {:ok, "processed"} =
             deliver(
               event("customer.subscription.deleted", stripe_subscription(uid), id: "evt_n4")
             )

    assert {"subscription_ended", %{"plan" => "premium"}} in notices(uid)

    # every job is a valid request of the contract: category billing, key per event
    for job <- all_enqueued(worker: NotifyWorker) do
      assert %{"category" => "billing", "dedupe_key" => "billing:" <> _} = job.args
    end
  end

  test "local simulated mode: the same pipeline notifies the activation", %{user_id: uid} do
    put_billing_env(:stripe, [])

    {:ok, %{session_id: id}} =
      MlBilling.create_checkout(uid, %{
        "plan" => "vip",
        "success_url" => "http://localhost:4000/membership/success",
        "cancel_url" => "http://localhost:4000/membership/cancel"
      })

    assert :ok = MlBilling.simulate_payment(uid, id, %{"outcome" => "succeeded"})
    assert [{"subscription_activated", %{"plan" => "vip"}}] = notices(uid)
  end

  test "the worker delivers to the center; a refusal cancels, an outage retries" do
    args = %{
      "user_id" => uuid(),
      "category" => "billing",
      "kind" => "payment_failed",
      "params" => %{"plan" => "vip"},
      "dedupe_key" => "billing:payment_failed:sub:1"
    }

    run = fn status ->
      Req.Test.stub(MlShared.Client, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"status" => "created"})
      end)

      perform_job(NotifyWorker, args)
    end

    assert :ok = run.(201)
    assert {:cancel, _} = run.(403)
    assert {:error, _} = run.(503)
  end
end
