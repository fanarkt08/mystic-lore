defmodule MlBilling.Privacy do
  @moduledoc """
  Export and deletion of a member's billing data. Deletion cancels the subscription at once so the member is
  never charged again; invoices and the credit ledger are kept without personal data.
  """
  import Ecto.Query

  alias MlBilling.{
    CheckoutSession,
    CreditAccount,
    CreditEntry,
    Invoice,
    Repo,
    Stripe,
    Subscription
  }

  alias MlBilling.WebhookEvent

  def export(user_id) do
    sub = Repo.get_by(Subscription, user_id: user_id)
    account = Repo.get(CreditAccount, user_id)

    %{
      "entitlements" => MlBilling.entitlements(user_id),
      "subscription" =>
        sub &&
          Map.take(sub, [
            :plan,
            :status,
            :provider,
            :current_period_start,
            :current_period_end,
            :cancel_at_period_end,
            :inserted_at
          ]),
      "invoices" =>
        Repo.all(
          from i in Invoice,
            where: i.user_id == ^user_id,
            order_by: [i.inserted_at, i.id],
            select: %{
              "id" => i.id,
              "amount_cents" => i.amount_cents,
              "currency" => i.currency,
              "status" => i.status,
              "period_start" => i.period_start,
              "period_end" => i.period_end,
              "hosted_url" => i.hosted_url,
              "inserted_at" => i.inserted_at
            }
        ),
      "checkouts" =>
        for s <-
              Repo.all(
                from s in CheckoutSession, where: s.user_id == ^user_id, order_by: s.inserted_at
              ) do
          %{
            "plan" => s.plan,
            "status" => CheckoutSession.status(s),
            "provider" => s.provider,
            "inserted_at" => s.inserted_at
          }
        end,
      "credits" => %{
        "account" =>
          account && Map.take(account, [:balance, :reserved, :allocation, :plan, :period]),
        "ledger" =>
          Repo.all(
            from e in CreditEntry,
              where: e.user_id == ^user_id,
              order_by: e.seq,
              select: %{
                "kind" => e.kind,
                "amount" => e.amount,
                "delta" => e.delta,
                "balance_after" => e.balance_after,
                "ref" => e.ref,
                "reason" => e.reason,
                "period" => e.period,
                "inserted_at" => e.inserted_at
              }
          )
      }
    }
  end

  @doc "`:ok`, or `{:error, :provider_error}` when Stripe is unreachable or refuses (retry later)."
  def delete(user_id) do
    now = DateTime.utc_now(:second)

    with :ok <- expire_checkouts(user_id, now),
         :ok <- terminate(Repo.get_by(Subscription, user_id: user_id), now) do
      Repo.update_all(from(i in Invoice, where: i.user_id == ^user_id),
        set: [hosted_url: nil, updated_at: now]
      )

      Repo.update_all(from(w in WebhookEvent, where: w.user_id == ^user_id), set: [payload: %{}])
      :ok
    end
  end

  defp expire_checkouts(user_id, now) do
    open =
      Repo.all(
        from s in CheckoutSession,
          where: s.user_id == ^user_id and s.status == "open" and s.expires_at > ^now
      )

    Enum.reduce_while(open, :ok, fn session, :ok ->
      if session.provider == "stripe" and
           stripe_refused?(Stripe.expire_checkout_session(session.provider_session_id)) do
        {:halt, {:error, :provider_error}}
      else
        Repo.update_all(from(s in CheckoutSession, where: s.id == ^session.id),
          set: [expires_at: now, updated_at: now]
        )

        {:cont, :ok}
      end
    end)
  end

  defp terminate(%Subscription{status: status} = sub, now) when status in ~w(active past_due) do
    if sub.provider == "stripe" and
         stripe_refused?(Stripe.cancel_subscription(sub.provider_subscription_id)) do
      {:error, :provider_error}
    else
      Repo.update_all(from(s in Subscription, where: s.id == ^sub.id),
        set: [
          status: "canceled",
          cancel_at_period_end: false,
          past_due_since: nil,
          current_period_end: now,
          last_event_at: now,
          updated_at: now
        ]
      )

      message = {:entitlements_changed, sub.user_id, "free"}
      MlShared.Events.broadcast("entitlements", message)
      MlShared.Events.broadcast(MlShared.Events.user(sub.user_id), message)
      :ok
    end
  end

  defp terminate(_none_or_ended, _now), do: :ok

  # Stripe 400/404: already canceled, expired or completed, nothing left to stop.
  defp stripe_refused?({:ok, _}), do: false
  defp stripe_refused?({:error, {:stripe, status}}) when status in [400, 404], do: false
  defp stripe_refused?(_error), do: true
end
