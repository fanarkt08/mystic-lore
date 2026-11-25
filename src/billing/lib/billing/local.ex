defmodule MlBilling.Local do
  @moduledoc """
  Local demo payment provider: no card, no money. It signs Stripe-format events and sends them through the
  same webhook pipeline as Stripe.
  """
  alias MlBilling.{Signature, Subscription, Webhooks}

  def secret do
    case Application.get_env(:billing, :local_webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        secret

      _ ->
        :crypto.mac(:hmac, :sha256, MlShared.InternalToken.secret(), "billing-local-webhook-v1")
        |> Base.encode16(case: :lower)
    end
  end

  def price_id(plan), do: "price_local_" <> plan
  def customer_id(user_id), do: "cus_local_" <> compact(user_id)
  def session_ref(session_id), do: "cs_local_" <> compact(session_id)

  @doc "Simulates the payment (`\"succeeded\"` or `\"failed\"`) of an open local checkout session."
  def simulate_payment(session, outcome) do
    now = DateTime.utc_now(:second)
    ref = compact(session.id)

    sub = %{
      id: "sub_local_" <> ref,
      user_id: session.user_id,
      plan: session.plan,
      status: "active",
      start: now,
      end: DateTime.shift(now, month: 1),
      cancel_at_period_end: false
    }

    invoice = invoice_object("in_local_" <> ref, sub, outcome == "succeeded")

    case outcome do
      "succeeded" ->
        emit_all(
          [
            {"evt_local_#{ref}_checkout", "checkout.session.completed",
             checkout_object(session, sub)},
            {"evt_local_#{ref}_subscription", "customer.subscription.created",
             subscription_object(sub)},
            {"evt_local_#{ref}_invoice", "invoice.paid", invoice}
          ],
          now
        )

      "failed" ->
        emit_all([{random_event_id(), "invoice.payment_failed", invoice}], now)
    end
  end

  @doc "Cancel at period end / resume: `customer.subscription.updated`."
  def set_cancel_at_period_end(%Subscription{} = sub, flag) do
    updated = subscription_object(from_row(sub, cancel_at_period_end: flag))
    emit_all([{random_event_id(), "customer.subscription.updated", updated}])
  end

  @doc "Ends or renews a local subscription at the end of its period, as Stripe does."
  def end_period(%Subscription{current_period_end: end_at} = sub) do
    ref = "#{sub.provider_subscription_id}_#{DateTime.to_unix(end_at)}"

    cond do
      sub.cancel_at_period_end ->
        emit_all([
          {"evt_local_#{ref}_deleted", "customer.subscription.deleted",
           subscription_object(from_row(sub, status: "canceled"))}
        ])

      sub.status == "active" ->
        next = from_row(sub, start: end_at, end: DateTime.shift(end_at, month: 1))

        emit_all([
          {"evt_local_#{ref}_invoice", "invoice.paid", invoice_object("in_#{ref}", next, true)},
          {"evt_local_#{ref}_renewal", "customer.subscription.updated", subscription_object(next)}
        ])

      true ->
        :ok
    end
  end

  defp emit_all(events, now \\ DateTime.utc_now(:second)) do
    Enum.reduce_while(events, :ok, fn {id, type, object}, :ok ->
      case emit(id, type, object, now) do
        {:ok, _status} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp emit(id, type, object, now) do
    created = DateTime.to_unix(now)

    raw =
      Jason.encode!(%{
        "id" => id,
        "object" => "event",
        "type" => type,
        "created" => created,
        "livemode" => false,
        "data" => %{"object" => object}
      })

    Webhooks.handle("local", raw, Signature.header(raw, secret(), created))
  end

  defp from_row(sub, overrides) do
    Map.merge(
      %{
        id: sub.provider_subscription_id,
        user_id: sub.user_id,
        plan: sub.plan,
        status: sub.status,
        start: sub.current_period_start,
        end: sub.current_period_end,
        cancel_at_period_end: sub.cancel_at_period_end
      },
      Map.new(overrides)
    )
  end

  defp checkout_object(session, sub) do
    %{
      "id" => session.provider_session_id,
      "object" => "checkout.session",
      "mode" => "subscription",
      "status" => "complete",
      "payment_status" => "paid",
      "client_reference_id" => session.user_id,
      "customer" => customer_id(session.user_id),
      "subscription" => sub.id,
      "metadata" => metadata(sub)
    }
  end

  defp subscription_object(sub) do
    period = %{
      "current_period_start" => DateTime.to_unix(sub.start),
      "current_period_end" => DateTime.to_unix(sub.end)
    }

    Map.merge(period, %{
      "id" => sub.id,
      "object" => "subscription",
      "customer" => customer_id(sub.user_id),
      "status" => sub.status,
      "cancel_at_period_end" => sub.cancel_at_period_end,
      "metadata" => metadata(sub),
      "items" => %{
        "object" => "list",
        "data" => [Map.put(period, "price", %{"id" => price_id(sub.plan)})]
      }
    })
  end

  defp invoice_object(id, sub, paid?) do
    amount = MlBilling.plan(sub.plan).price_cents

    %{
      "id" => id,
      "object" => "invoice",
      "customer" => customer_id(sub.user_id),
      "status" => if(paid?, do: "paid", else: "open"),
      "amount_due" => amount,
      "amount_paid" => if(paid?, do: amount, else: 0),
      "currency" => MlBilling.currency(),
      "hosted_invoice_url" => nil,
      "lines" => %{
        "object" => "list",
        "data" => [
          %{
            "period" => %{
              "start" => DateTime.to_unix(sub.start),
              "end" => DateTime.to_unix(sub.end)
            }
          }
        ]
      },
      "parent" => %{
        "type" => "subscription_details",
        "subscription_details" => %{"subscription" => sub.id, "metadata" => metadata(sub)}
      }
    }
  end

  defp metadata(sub), do: %{"user_id" => sub.user_id, "plan" => sub.plan}

  defp random_event_id,
    do: "evt_local_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp compact(uuid), do: String.replace(uuid, "-", "")
end
