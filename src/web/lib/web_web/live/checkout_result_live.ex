defmodule MysticWeb.CheckoutResultLive do
  @moduledoc """
  Return pages of a checkout. The success page only waits for billing's confirmation and never unlocks anything.
  """
  use MysticWeb, :live_view

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :cancel}} = socket),
    do: {:ok, assign(socket, page_title: gettext("Checkout canceled"))}

  def mount(params, _session, socket) do
    socket =
      assign(socket,
        page_title: gettext("Payment status"),
        session_id: params["session_id"],
        plan: nil
      )

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info({:entitlements_changed, _user_id, _plan}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  defp refresh(%{assigns: %{session_id: id}} = socket) when id in [nil, ""],
    do: assign(socket, state: :missing)

  defp refresh(socket) do
    with {:ok, %{"plan" => _} = checkout} <-
           Api.get(socket, :billing, "/api/checkout/:id",
             path_params: [id: socket.assigns.session_id]
           ),
         {:ok, %{"entitlements" => entitlements}} <- Api.get(socket, :billing, "/api/me/billing") do
      assign(socket, plan: entitlements["plan"], state: state(checkout, entitlements))
    else
      {:error, {:http, 404, _}} -> assign(socket, state: :not_found)
      _ -> assign(socket, state: :unavailable)
    end
  end

  # Activated once billing reports the session completed and a paid effective plan.
  defp state(%{"status" => "completed"}, %{"plan" => plan}) when plan != "free", do: :active
  defp state(%{"status" => "expired"}, _entitlements), do: :failed
  defp state(_checkout, _entitlements), do: :waiting

  defp plan_name("vip"), do: gettext("VIP")
  defp plan_name(_premium), do: gettext("Premium")

  @impl true
  def render(%{live_action: :cancel} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:membership}
    >
      <div class="mx-auto max-w-2xl">
        <.access_state
          id="checkout-canceled"
          icon="hero-x-circle"
          tone="info"
          heading="h1"
          title={gettext("Checkout canceled")}
        >
          {gettext("No payment was made and your plan hasn't changed.")}
          <:actions>
            <.button navigate={~p"/membership"} variant="secondary">
              {gettext("Back to membership")}
            </.button>
          </:actions>
        </.access_state>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:membership}
    >
      <section
        class="mx-auto max-w-2xl card space-y-5 text-center md:p-10"
        aria-labelledby="status-title"
      >
        <div id="payment-status" aria-live="polite" class="space-y-4">
          <%= case @state do %>
            <% :active -> %>
              <span class="feature-icon feature-icon-reward mx-auto"><.icon name="hero-sparkles" /></span>
              <h1 id="status-title" class="text-4xl md:text-5xl">
                {gettext("Welcome to %{plan}", plan: plan_name(@plan))}
              </h1>
              <p class="text-muted">
                {gettext(
                  "Your payment is confirmed and your membership is active. Every premium chapter is now open."
                )}
              </p>
              <div class="flex flex-wrap justify-center gap-2">
                <.button navigate={~p"/adventures"} variant="reward">{gettext("Explore adventures")}</.button>
                <.button navigate={~p"/dashboard"} variant="secondary">{gettext("Go to dashboard")}</.button>
              </div>
            <% :waiting -> %>
              <span class="spinner mx-auto" aria-hidden="true"></span>
              <h1 id="status-title" class="text-4xl">
                {gettext("Waiting for payment confirmation…")}
              </h1>
              <p class="text-muted">
                {gettext(
                  "Your plan is activated only when the payment provider's signed confirmation reaches billing. This page updates by itself."
                )}
              </p>
              <.button phx-click="refresh" variant="secondary" id="check-again">{gettext(
                "Check again"
              )}</.button>
            <% :failed -> %>
              <span class="feature-icon mx-auto"><.icon name="hero-exclamation-triangle" /></span>
              <h1 id="status-title" class="text-4xl">{gettext("Payment not completed")}</h1>
              <p class="text-muted">
                {gettext("This checkout has expired or the payment failed. Nothing was charged.")}
              </p>
              <.button navigate={~p"/membership"} id="checkout-start-again">
                {gettext("Start a new checkout")}
              </.button>
            <% :not_found -> %>
              <h1 id="status-title" class="text-4xl">{gettext("Checkout not found")}</h1>
              <p class="text-muted">
                {gettext("This checkout session doesn't exist or belongs to another account.")}
              </p>
            <% :missing -> %>
              <h1 id="status-title" class="text-4xl">{gettext("No checkout to follow")}</h1>
              <p class="text-muted">{gettext("Start from the membership page to choose a plan.")}</p>
            <% :unavailable -> %>
              <h1 id="status-title" class="text-4xl">{gettext("Payment status")}</h1>
              <.unavailable>{gettext("The payment status can't be checked right now.")}</.unavailable>
              <.button phx-click="refresh" variant="secondary">{gettext("Check again")}</.button>
          <% end %>
        </div>
        <.link :if={@state != :active} navigate={~p"/membership"} class="link inline-block">
          {gettext("Back to membership")}
        </.link>
      </section>
    </Layouts.app>
    """
  end
end
