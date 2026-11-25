defmodule MlBilling.TestHelpers do
  @moduledoc "Signed Stripe-format events and configuration switches (restored on exit) for tests."
  import ExUnit.Callbacks, only: [on_exit: 1]

  @stripe [
    secret_key: "sk_test_fixture",
    webhook_secret: "whsec_test_fixture",
    price_premium: "price_premium_fx",
    price_vip: "price_vip_fx"
  ]

  def uuid, do: Ecto.UUID.generate()

  def use_stripe(overrides \\ []), do: put_billing_env(:stripe, Keyword.merge(@stripe, overrides))

  def put_billing_env(key, value) do
    previous = Application.fetch_env(:billing, key)
    Application.put_env(:billing, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:billing, key, value)
        :error -> Application.delete_env(:billing, key)
      end
    end)
  end

  def event(type, object, opts \\ []) do
    %{
      "id" => opts[:id] || "evt_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      "object" => "event",
      "type" => type,
      "created" => opts[:created] || System.os_time(:second),
      "livemode" => false,
      "data" => %{"object" => object}
    }
  end

  def signed(event, secret \\ "whsec_test_fixture", timestamp \\ System.os_time(:second)) do
    raw = Jason.encode!(event)
    {raw, MlBilling.Signature.header(raw, secret, timestamp)}
  end

  @doc "Stripe subscription object (recent API shape: period on the subscription item)."
  def stripe_subscription(user_id, opts \\ []) do
    now = System.os_time(:second)

    %{
      "id" => opts[:id] || "sub_test_1",
      "object" => "subscription",
      "customer" => opts[:customer] || "cus_test_1",
      "status" => opts[:status] || "active",
      "cancel_at_period_end" => opts[:cancel_at_period_end] || false,
      "metadata" => %{"user_id" => user_id, "plan" => "premium"},
      "items" => %{
        "object" => "list",
        "data" => [
          %{
            "price" => %{"id" => opts[:price] || "price_premium_fx"},
            "current_period_start" => now,
            "current_period_end" => now + 30 * 86_400
          }
        ]
      }
    }
  end

  def stripe_invoice(opts \\ []) do
    %{
      "id" => opts[:id] || "in_test_1",
      "object" => "invoice",
      "customer" => "cus_test_1",
      "subscription" => opts[:subscription] || "sub_test_1",
      "status" => opts[:status] || "open",
      "amount_due" => 1200,
      "amount_paid" => opts[:amount_paid] || 0,
      "currency" => "usd",
      "hosted_invoice_url" => "https://invoice.stripe.com/i/test_1"
    }
  end
end
