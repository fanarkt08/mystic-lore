defmodule MlBillingWeb.CheckoutController do
  use MlBillingWeb, :controller
  alias MlBilling.CheckoutSession

  action_fallback MlBillingWeb.FallbackController

  def create(conn, _params) do
    with {:ok, checkout} <- MlBilling.create_checkout(conn.assigns.user_id, conn.body_params),
         do: conn |> put_status(201) |> json(checkout)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, session} <- MlBilling.get_checkout(conn.assigns.user_id, id) do
      json(conn, %{
        session_id: session.id,
        plan: session.plan,
        status: CheckoutSession.status(session),
        mode: session.provider
      })
    end
  end

  # Local DEMO mode only. Processed synchronously by the webhook pipeline before replying.
  def simulate(conn, %{"id" => id}) do
    with :ok <- MlBilling.simulate_payment(conn.assigns.user_id, id, conn.body_params),
         do: conn |> put_status(202) |> json(%{status: "processing"})
  end
end
