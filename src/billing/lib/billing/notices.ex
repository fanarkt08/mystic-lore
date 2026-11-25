defmodule MlBilling.Notices do
  @moduledoc """
  Notifications de la catégorie `billing`, déduites de l'abonnement avant et après chaque changement.
  """
  alias MlBilling.{NotifyWorker, Subscription}

  @doc "Tâches de notification du passage de `old` à `new` (même membre)."
  def transition!(%Subscription{} = old, %Subscription{} = new) do
    for {kind, key} <- changes(old, new) do
      %{
        user_id: new.user_id,
        category: "billing",
        kind: kind,
        params: params(kind, old, new),
        dedupe_key: "billing:#{kind}:#{new.provider_subscription_id}:#{key}"
      }
      |> NotifyWorker.new()
      |> Oban.insert!()
    end

    :ok
  end

  def transition!(_old, _new), do: :ok

  @doc false
  def changes(old, new) do
    running = ~w(active past_due)

    [
      (new.status == "active" and old.status != "past_due" and
         (old.status != "active" or old.plan != new.plan or
            old.provider_subscription_id != new.provider_subscription_id)) &&
        {"subscription_activated", new.plan},
      (new.status == "past_due" and old.status != "past_due") &&
        {"payment_failed", unix(new.past_due_since)},
      (new.status in running and new.cancel_at_period_end and not old.cancel_at_period_end) &&
        {"cancellation_scheduled", unix(new.current_period_end)},
      (new.status == "canceled" and old.status in running) && {"subscription_ended", old.plan}
    ]
    |> Enum.filter(& &1)
  end

  defp params("subscription_ended", old, _new), do: %{plan: paid(old.plan)}

  defp params("cancellation_scheduled", _old, new),
    do: %{plan: paid(new.plan), period_end: new.current_period_end}

  defp params(_kind, _old, new), do: %{plan: paid(new.plan)}

  defp paid(plan) when plan in ~w(premium vip), do: plan
  defp paid(_plan), do: "premium"

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(_at), do: "none"
end
