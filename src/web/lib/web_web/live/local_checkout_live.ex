defmodule MysticWeb.LocalCheckoutLive do
  @moduledoc """
  Simulated payment page of billing's local mode. Nothing is unlocked here: billing waits for the signed events.
  """
  use MysticWeb, :live_view

  @impl true
  def mount(%{"session_id" => id}, _session, socket) do
    checkout =
      case Api.get(socket, :billing, "/api/checkout/:id", path_params: [id: id]) do
        {:ok, %{"session_id" => _} = checkout} -> checkout
        {:error, {:http, 404, _}} -> :not_found
        _ -> :unavailable
      end

    plan =
      with %{"plan" => key} <- checkout,
           {:ok, %{"plans" => plans}} <- Api.get(socket, :billing, "/api/plans") do
        Enum.find(plans, &(&1["key"] == key))
      else
        _ -> nil
      end

    {:ok,
     assign(socket,
       page_title: gettext("Demo checkout"),
       session_id: id,
       checkout: checkout,
       plan: plan,
       failed: false
     )}
  end

  @impl true
  def handle_event("simulate", %{"outcome" => outcome}, socket)
      when outcome in ["succeeded", "failed"] do
    id = socket.assigns.session_id

    case Api.post(socket, :billing, "/api/checkout/:id/simulate-payment",
           path_params: [id: id],
           json: %{outcome: outcome}
         ) do
      {:ok, _} when outcome == "failed" ->
        {:noreply, assign(socket, failed: true)}

      {:ok, _} ->
        {:noreply, push_navigate(socket, to: ~p"/membership/success?#{[session_id: id]}")}

      {:error, {:http, 404, _}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Simulated payments are only available in demo payment mode.")
         )}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:membership}
    >
      <div class="mx-auto max-w-2xl space-y-6">
        <%= case @checkout do %>
          <% :unavailable -> %>
            <.unavailable id="checkout-unavailable">
              {gettext("This checkout can't be loaded right now.")}
            </.unavailable>
          <% :not_found -> %>
            <.notice id="checkout-not-found" kind="danger" title={gettext("Checkout not found")}>
              {gettext("This checkout session doesn't exist or belongs to another account.")}
              <:actions>
                <.button navigate={~p"/membership"} variant="secondary">{gettext("Back to membership")}</.button>
              </:actions>
            </.notice>
          <% %{"mode" => mode} when mode != "local" -> %>
            <.notice id="checkout-not-local" kind="warning" title={gettext("Not a demo checkout")}>
              {gettext("Simulated payments are only available in demo payment mode.")}
              <:actions>
                <.button navigate={~p"/membership"} variant="secondary">{gettext("Back to membership")}</.button>
              </:actions>
            </.notice>
          <% %{"status" => "expired"} -> %>
            <.access_state
              id="checkout-closed"
              icon="hero-clock"
              title={gettext("This checkout has expired")}
            >
              {gettext(
                "A checkout session only lasts a limited time. Nothing was charged and your plan hasn't changed: start a new checkout from the membership page."
              )}
              <:actions>
                <.button navigate={~p"/membership"} id="checkout-restart">
                  {gettext("Start a new checkout")}
                </.button>
              </:actions>
            </.access_state>
          <% %{"status" => status} when status != "open" -> %>
            <.access_state
              id="checkout-closed"
              icon="hero-check-circle"
              tone="info"
              title={gettext("This checkout is already paid")}
            >
              {gettext(
                "This session can't be paid again. Its status says whether your plan is active."
              )}
              <:actions>
                <.button
                  navigate={~p"/membership/success?#{[session_id: @session_id]}"}
                  variant="secondary"
                >
                  {gettext("See payment status")}
                </.button>
              </:actions>
            </.access_state>
          <% checkout -> %>
            <section id="demo-checkout" class="card space-y-6 md:p-8" aria-labelledby="demo-title">
              <p class="demo-ribbon">
                <.icon name="hero-beaker" class="size-4" />
                {gettext("DEMO — simulated payment, no real money")}
              </p>
              <div class="space-y-2">
                <h1 id="demo-title" class="text-4xl">{gettext("Demo checkout")}</h1>
                <p class="text-muted">
                  {gettext(
                    "This page imitates a payment provider so the whole subscription flow can be tried safely."
                  )}
                </p>
              </div>

              <div id="payment-feedback" aria-live="polite">
                <.notice
                  :if={@failed}
                  id="payment-failed"
                  kind="danger"
                  title={gettext("Payment failed (simulated)")}
                >
                  {gettext("Nothing was charged and your plan hasn't changed. You can try again.")}
                </.notice>
              </div>

              <dl class="summary-list">
                <div>
                  <dt>{gettext("Plan")}</dt>
                  <dd class="font-medium text-ink">
                    {(@plan && MysticWeb.MysticComponents.plan_title(@plan)) || checkout["plan"]}
                  </dd>
                </div>
                <div :if={@plan}>
                  <dt>{gettext("Price")}</dt>
                  <dd class="tabular-nums">
                    {money(@plan["price_cents"], @plan["currency"])} {if @plan["interval"] == "month",
                      do: gettext("per month")}
                  </dd>
                </div>
                <div>
                  <dt>{gettext("Card")}</dt>
                  <dd class="font-mono text-sm">
                    •••• •••• •••• 4242
                    <span class="font-sans text-muted">({gettext("fictional — nothing to enter")})</span>
                  </dd>
                </div>
              </dl>

              <div class="flex flex-wrap gap-3">
                <.button
                  phx-click="simulate"
                  phx-value-outcome="succeeded"
                  id="pay"
                  phx-disable-with={gettext("Processing…")}
                >
                  <.icon name="hero-lock-closed" /> {gettext("Pay (simulated)")}
                </.button>
                <.button
                  phx-click="simulate"
                  phx-value-outcome="failed"
                  variant="danger"
                  id="simulate-failure"
                  phx-disable-with={gettext("Processing…")}
                >
                  {gettext("Simulate failure")}
                </.button>
                <.button navigate={~p"/membership/cancel"} variant="ghost">{gettext("Cancel")}</.button>
              </div>
              <p class="text-xs text-muted">
                {gettext(
                  "Your plan changes only once billing has processed the (simulated) signed payment event."
                )}
              </p>
            </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
