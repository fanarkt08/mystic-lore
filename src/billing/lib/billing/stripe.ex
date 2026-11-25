defmodule MlBilling.Stripe do
  @moduledoc """
  Minimal Stripe REST client. No card data transits here: the payment happens on Stripe Checkout.
  """
  require Logger

  @base_url "https://api.stripe.com"

  def configured?,
    do: Enum.all?([:secret_key, :webhook_secret, :price_premium, :price_vip], &present?(conf(&1)))

  def webhook_secret, do: conf(:webhook_secret)
  def price_id("premium"), do: conf(:price_premium)
  def price_id("vip"), do: conf(:price_vip)

  def create_checkout_session(form, idempotency_key),
    do: request(:post, "/v1/checkout/sessions", form, [{"idempotency-key", idempotency_key}])

  def create_portal_session(customer, return_url),
    do:
      request(:post, "/v1/billing_portal/sessions", [
        {"customer", customer},
        {"return_url", return_url}
      ])

  def set_cancel_at_period_end(subscription_id, flag) do
    with {:ok, path} <- subscription_path(subscription_id),
         do: request(:post, path, [{"cancel_at_period_end", to_string(flag)}])
  end

  @doc "Immediate cancellation, unused time credited to the customer (`prorate=true`)."
  def cancel_subscription(subscription_id) do
    with {:ok, path} <- subscription_path(subscription_id),
         do: request(:delete, path, [{"prorate", "true"}])
  end

  @doc "Expires an open Checkout Session so that it can no longer be paid."
  def expire_checkout_session(session_id) do
    if is_binary(session_id) and Regex.match?(~r/\Acs_\w+\z/, session_id),
      do: request(:post, "/v1/checkout/sessions/#{session_id}/expire", []),
      else: {:error, :invalid_session_id}
  end

  defp subscription_path(id) do
    if is_binary(id) and Regex.match?(~r/\Asub_\w+\z/, id),
      do: {:ok, "/v1/subscriptions/" <> id},
      else: {:error, :invalid_subscription_id}
  end

  defp request(method, path, params, headers \\ []) do
    key = conf(:secret_key)

    if present?(key) do
      [method: method, base_url: @base_url, url: path, auth: {:bearer, key}, headers: headers]
      |> Keyword.put(if(method == :delete, do: :params, else: :form), params)
      |> Keyword.merge(retry: false, receive_timeout: 15_000)
      |> Keyword.merge(Application.get_env(:billing, :stripe_req_options, []))
      |> Req.request()
      |> handle(method, path)
    else
      {:error, :not_configured}
    end
  end

  defp handle({:ok, %Req.Response{status: status, body: %{} = body}}, _, _)
       when status in 200..299,
       do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}, method, path) do
    Logger.warning("stripe #{method} #{path}: HTTP #{status} #{error_code(body)}")
    {:error, {:stripe, status}}
  end

  defp handle({:error, exception}, method, path) do
    Logger.warning("stripe #{method} #{path}: #{Exception.message(exception)}")
    {:error, :unavailable}
  end

  defp error_code(%{"error" => %{} = error}), do: error["code"] || error["type"]
  defp error_code(_), do: nil

  defp conf(key), do: Application.get_env(:billing, :stripe, [])[key]
  defp present?(value), do: is_binary(value) and value != ""
end
