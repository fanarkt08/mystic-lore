defmodule MlBillingWeb.Router do
  use MlBillingWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :service do
    plug MlShared.Plug.Internal
  end

  pipeline :user do
    plug MlShared.Plug.Internal, user: :required
  end

  # No internal token: health check, and the Stripe webhook (authenticated by its signature).
  scope "/", MlBillingWeb do
    pipe_through :api

    get "/healthz", BillingController, :health
    post "/webhooks/stripe", WebhookController, :stripe
  end

  scope "/api", MlBillingWeb do
    pipe_through [:api, :service]

    get "/plans", BillingController, :plans
    get "/entitlements/:user_id", BillingController, :entitlements

    # AI credits, service-only (caller allow-list in MlBillingWeb.CreditController)
    post "/internal/credits/reserve", CreditController, :reserve
    post "/internal/credits/consume", CreditController, :consume
    post "/internal/credits/release", CreditController, :release

    # personal data: caller accounts only (403 otherwise)
    get "/internal/users/:id/export", PrivacyController, :export
    delete "/internal/users/:id", PrivacyController, :delete
  end

  scope "/api", MlBillingWeb do
    pipe_through [:api, :user]

    get "/me/billing", BillingController, :me
    get "/me/credits", CreditController, :me
    post "/me/subscription/cancel", BillingController, :cancel
    post "/me/subscription/resume", BillingController, :resume
    post "/portal", BillingController, :portal
    post "/checkout", CheckoutController, :create
    get "/checkout/:id", CheckoutController, :show
    post "/checkout/:id/simulate-payment", CheckoutController, :simulate

    # admin : lecture des abonnements et webhooks, ajustement de crédits
    get "/admin/stats", AdminController, :stats
    get "/admin/subscriptions", AdminController, :subscriptions
    get "/admin/webhook-events", AdminController, :webhook_events
    post "/admin/credits/adjustments", AdminController, :adjust_credits
  end
end
