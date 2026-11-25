defmodule MlBillingWeb.WebhookController do
  @moduledoc "`POST /webhooks/stripe`: no internal token, authenticated by the `Stripe-Signature` header."
  use MlBillingWeb, :controller
  require Logger

  def stripe(conn, _params) do
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case MlBilling.Webhooks.handle("stripe", conn.assigns[:raw_body] || "", signature) do
      {:ok, status} ->
        json(conn, %{status: status})

      {:error, :invalid_payload} ->
        conn |> put_status(400) |> json(%{error: "invalid_payload"})

      {:error, reason} ->
        Logger.warning("stripe webhook rejected: #{reason}")
        conn |> put_status(400) |> json(%{error: "invalid_signature"})
    end
  end
end
