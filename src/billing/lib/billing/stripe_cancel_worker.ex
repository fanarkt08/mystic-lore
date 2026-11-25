defmodule MlBilling.StripeCancelWorker do
  @moduledoc "Cancels at Stripe a subscription replaced by a newer one, so the user is never billed twice."
  use Oban.Worker, queue: :default, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id}}) do
    case MlBilling.Stripe.cancel_subscription(id) do
      {:ok, _subscription} -> :ok
      {:error, {:stripe, status}} when status in [400, 404] -> {:cancel, "stripe HTTP #{status}"}
      {:error, :invalid_subscription_id} -> {:cancel, :invalid_subscription_id}
      error -> error
    end
  end
end
