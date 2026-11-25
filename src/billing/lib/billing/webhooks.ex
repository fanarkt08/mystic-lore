defmodule MlBilling.Webhooks do
  @moduledoc """
  Processing pipeline for Stripe-format events: signature check, deduplication, then one transaction per event.
  An event older than the last applied one is recorded as `stale` without effect.
  """
  import Ecto.Query
  require Logger
  alias Ecto.Changeset
  alias MlBilling.{CheckoutSession, Invoice, Local, Repo, Stripe, Subscription, WebhookEvent}

  # Customer personal data that is never needed: not kept in the stored payload.
  @pii ~w(customer_details customer_email customer_name customer_address customer_phone
          customer_shipping shipping_details)

  @doc "`{:ok, status} | {:error, :invalid_signature | :expired_signature | :invalid_payload}`."
  def handle(provider, raw_body, signature_header) when provider in ["stripe", "local"] do
    with :ok <- MlBilling.Signature.verify(raw_body, signature_header, secret(provider)),
         {:ok, event} <- decode(raw_body) do
      process(provider, event)
    end
  end

  defp secret("stripe"), do: Stripe.webhook_secret()
  defp secret("local"), do: Local.secret()

  defp decode(raw_body) do
    with {:ok,
          %{"id" => id, "type" => type, "created" => created, "data" => %{"object" => obj}} = p}
         when is_binary(id) and is_binary(type) and is_integer(created) and is_map(obj) <-
           Jason.decode(raw_body),
         {:ok, at} <- DateTime.from_unix(created) do
      payload = put_in(p, ["data", "object"], Map.drop(obj, @pii))
      {:ok, %{id: id, type: type, at: at, object: obj, payload: payload}}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp process(provider, event) do
    {:ok, {status, changed}} =
      Repo.transact(fn ->
        case insert_event(provider, event) do
          nil ->
            {:ok, {"duplicate", nil}}

          event_id ->
            {status, user_id, changed, error} = apply_event(provider, event)

            from(e in WebhookEvent, where: e.id == ^event_id)
            |> Repo.update_all(set: [status: status, user_id: user_id, error: error])

            {:ok, {status, changed}}
        end
      end)

    Logger.info("webhook #{provider} #{event.type} #{event.id}: #{status}")
    if changed, do: MlBilling.broadcast(changed)
    {:ok, status}
  end

  defp insert_event(provider, event) do
    row = %{
      id: Ecto.UUID.generate(),
      provider: provider,
      provider_event_id: event.id,
      type: event.type,
      event_created_at: event.at,
      status: "received",
      payload: event.payload,
      inserted_at: DateTime.utc_now(:second)
    }

    case Repo.insert_all(WebhookEvent, [row],
           on_conflict: :nothing,
           conflict_target: [:provider, :provider_event_id]
         ) do
      {1, _} -> row.id
      {0, _} -> nil
    end
  end

  # -> {status, user_id | nil, updated subscription | nil, error | nil}
  defp apply_event(provider, %{type: "checkout.session.completed", object: %{"id" => id}})
       when is_binary(id) do
    case Repo.get_by(CheckoutSession, provider: provider, provider_session_id: id) do
      nil ->
        {"ignored", nil, nil, "unknown_checkout_session"}

      session ->
        from(s in CheckoutSession, where: s.id == ^session.id)
        |> Repo.update_all(set: [status: "completed", updated_at: DateTime.utc_now(:second)])

        {"processed", session.user_id, nil, nil}
    end
  end

  defp apply_event(
         provider,
         %{type: "customer.subscription." <> action, object: %{"id" => sid} = obj} = event
       )
       when action in ~w(created updated deleted) and is_binary(sid) do
    attrs = subscription_attrs(provider, obj, action)
    user_id = find_user(provider, sid, obj["customer"], obj["metadata"])

    cond do
      is_nil(user_id) -> {"failed", nil, nil, "unknown_user"}
      is_nil(attrs.plan) and action != "deleted" -> {"failed", user_id, nil, "unknown_price"}
      true -> apply_subscription(lock_subscription(user_id, provider), provider, attrs, event)
    end
  end

  defp apply_event(provider, %{type: "invoice." <> kind, object: %{"id" => id} = obj} = event)
       when kind in ~w(paid payment_failed) and is_binary(id) do
    details =
      get_in(obj, ["parent", "subscription_details"]) || obj["subscription_details"] || %{}

    sid = obj["subscription"] || details["subscription"]

    case find_user(provider, sid, obj["customer"], details["metadata"]) do
      nil ->
        {"failed", nil, nil, "unknown_user"}

      user_id ->
        sub = lock_subscription(user_id, provider)

        case put_invoice(provider, user_id, sid, obj, kind) do
          :outdated -> {"stale", user_id, nil, nil}
          _invoice -> {"processed", user_id, invoice_effect(sub, sid, kind, event), nil}
        end
    end
  end

  defp apply_event(_provider, _event), do: {"ignored", nil, nil, nil}

  defp subscription_attrs(provider, obj, action) do
    item = get_in(obj, ["items", "data", Access.at(0)]) || %{}

    %{
      plan: plan_for_price(provider, get_in(item, ["price", "id"])),
      status: if(action == "deleted", do: "canceled", else: status(obj["status"])),
      provider_subscription_id: obj["id"],
      provider_customer_id: obj["customer"],
      current_period_start: unix(obj["current_period_start"] || item["current_period_start"]),
      current_period_end: unix(obj["current_period_end"] || item["current_period_end"]),
      cancel_at_period_end: obj["cancel_at_period_end"] == true
    }
  end

  defp apply_subscription(sub, provider, attrs, event) do
    cond do
      stale?(sub, event) ->
        {"stale", sub.user_id, nil, nil}

      sub.provider_subscription_id not in [nil, attrs.provider_subscription_id] and
          attrs.status != "active" ->
        {"ignored", sub.user_id, nil, "other_subscription"}

      true ->
        updated = put_subscription(sub, provider, attrs, event)
        :ok = MlBilling.Notices.transition!(sub, updated)
        {"processed", sub.user_id, updated, nil}
    end
  end

  defp put_subscription(sub, provider, attrs, event) do
    same? = sub.provider_subscription_id == attrs.provider_subscription_id

    if not same? and sub.provider == "stripe" and sub.status in ~w(active past_due) do
      %{"subscription_id" => sub.provider_subscription_id}
      |> MlBilling.StripeCancelWorker.new()
      |> Oban.insert!()
    end

    changes = %{
      attrs
      | plan: attrs.plan || sub.plan,
        provider_customer_id: attrs.provider_customer_id || sub.provider_customer_id
    }

    sub
    |> Changeset.change(changes)
    |> Changeset.change(
      provider: provider,
      past_due_since:
        if(attrs.status == "past_due", do: (same? && sub.past_due_since) || event.at),
      last_event_at: event.at
    )
    |> Repo.update!()
  end

  # Payment failure / recovery of the current subscription (Stripe also sends
  # customer.subscription.updated; the local provider only sends the invoice event).
  defp invoice_effect(%Subscription{provider_subscription_id: sid} = sub, sid, kind, event)
       when is_binary(sid) do
    changes =
      case {kind, sub.status} do
        {"payment_failed", "active"} -> [status: "past_due", past_due_since: event.at]
        {"paid", "past_due"} -> [status: "active", past_due_since: nil]
        _ -> nil
      end

    if changes && not stale?(sub, event) do
      updated = sub |> Changeset.change([last_event_at: event.at] ++ changes) |> Repo.update!()
      :ok = MlBilling.Notices.transition!(sub, updated)
      updated
    end
  end

  defp invoice_effect(_sub, _sid, _kind, _event), do: nil

  defp put_invoice(provider, user_id, sid, obj, kind) do
    existing = Repo.get_by(Invoice, provider: provider, provider_invoice_id: obj["id"])

    # A paid invoice never goes back to failed (out-of-order events).
    if kind == "payment_failed" and match?(%Invoice{status: "paid"}, existing) do
      :outdated
    else
      period = get_in(obj, ["lines", "data", Access.at(0), "period"]) || %{}
      paid? = kind == "paid"

      (existing || %Invoice{})
      |> Changeset.change(
        user_id: user_id,
        provider: provider,
        provider_invoice_id: obj["id"],
        provider_subscription_id: sid,
        amount_cents: if(paid?, do: obj["amount_paid"], else: obj["amount_due"]) || 0,
        currency: String.downcase(obj["currency"] || MlBilling.currency()),
        status: if(paid?, do: "paid", else: "failed"),
        period_start: unix(period["start"] || obj["period_start"]),
        period_end: unix(period["end"] || obj["period_end"]),
        hosted_url: https_url(obj["hosted_invoice_url"])
      )
      |> Repo.insert_or_update!()
    end
  end

  defp lock_subscription(user_id, provider) do
    now = DateTime.utc_now(:second)

    placeholder = %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      provider: provider,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(Subscription, [placeholder], on_conflict: :nothing, conflict_target: :user_id)
    Repo.one!(from s in Subscription, where: s.user_id == ^user_id, lock: "FOR UPDATE")
  end

  # Known subscription or customer first, then the user_id put in the metadata at checkout.
  defp find_user(provider, sid, customer, metadata) do
    Enum.find_value([provider_subscription_id: sid, provider_customer_id: customer], fn
      {field, value} when is_binary(value) ->
        from(s in Subscription,
          where: s.provider == ^provider and field(s, ^field) == ^value,
          select: s.user_id,
          limit: 1
        )
        |> Repo.one()

      _ ->
        nil
    end) || metadata_user(metadata)
  end

  defp metadata_user(%{"user_id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp metadata_user(_), do: nil

  defp stale?(%Subscription{last_event_at: %DateTime{} = last}, %{at: at}),
    do: DateTime.before?(at, last)

  defp stale?(_sub, _event), do: false

  defp plan_for_price(provider, price) when is_binary(price),
    do: Enum.find(~w(premium vip), &(price_id(provider, &1) == price))

  defp plan_for_price(_provider, _price), do: nil

  defp price_id("stripe", plan), do: Stripe.price_id(plan)
  defp price_id("local", plan), do: Local.price_id(plan)

  defp status(s) when s in ~w(active trialing), do: "active"
  defp status(s) when s in ~w(past_due unpaid), do: "past_due"
  defp status(s) when s in ~w(canceled incomplete_expired), do: "canceled"
  defp status(_incomplete_or_paused), do: "none"

  defp unix(t) when is_integer(t), do: DateTime.from_unix!(t)
  defp unix(_), do: nil

  defp https_url("https://" <> _ = url), do: url
  defp https_url(_), do: nil
end
