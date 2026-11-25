defmodule MysticWeb.MembershipLive do
  @moduledoc """
  Plans, subscription, invoices and AI credits. The page never changes a plan itself.
  """
  use MysticWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    plans =
      case Api.get(socket, :billing, "/api/plans") do
        {:ok, %{"plans" => plans} = body} -> %{list: plans, mode: body["mode"]}
        _ -> :unavailable
      end

    {:ok,
     socket
     |> assign(page_title: gettext("Membership"), plans: plans)
     |> load_billing()
     |> load_credits()}
  end

  defp load_credits(socket) do
    case Api.get(socket, :billing, "/api/me/credits") do
      {:ok, %{"balance" => _} = credits} -> assign(socket, credits: credits)
      _ -> assign(socket, credits: :unavailable)
    end
  end

  defp load_billing(socket) do
    case Api.get(socket, :billing, "/api/me/billing") do
      {:ok, %{"entitlements" => %{}} = billing} -> set_billing(socket, billing)
      _ -> set_billing(socket, :unavailable)
    end
  end

  defp set_billing(socket, billing) do
    assign(socket,
      billing: billing,
      mode: mode(socket.assigns.plans, billing),
      current: current_plan(billing)
    )
  end

  @impl true
  def handle_info({:entitlements_changed, _user_id, _plan}, socket),
    do: {:noreply, socket |> load_billing() |> load_credits()}

  def handle_info({:credits_changed, _user_id, _balance}, socket),
    do: {:noreply, load_credits(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("checkout", %{"plan" => plan}, socket) when plan in ["premium", "vip"] do
    base = web_url()

    body = %{
      plan: plan,
      success_url: base <> "/membership/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: base <> "/membership/cancel"
    }

    case Api.post(socket, :billing, "/api/checkout", json: body) do
      {:ok, %{"url" => url}} when is_binary(url) -> {:noreply, go(socket, url)}
      {:ok, _} -> {:noreply, go(socket, nil)}
      error -> {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event(action, _params, socket) when action in ["cancel", "resume"] do
    case Api.post(socket, :billing, "/api/me/subscription/#{action}") do
      {:ok, %{"plan" => _} = entitlements} ->
        message =
          if action == "cancel",
            do: gettext("Your subscription will end at the end of the current period."),
            else: gettext("Your subscription will continue.")

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> set_billing(update_entitlements(socket.assigns.billing, entitlements))}

      {:error, {:http, 404, _}} ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have a subscription in progress."))}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("portal", _params, socket) do
    case Api.post(socket, :billing, "/api/portal",
           json: %{return_url: web_url() <> "/membership"}
         ) do
      {:ok, %{"url" => url}} when is_binary(url) ->
        {:noreply, go(socket, url)}

      {:error, {:http, 404, _}} ->
        message = gettext("The billing portal isn't available in demo payment mode.")
        {:noreply, put_flash(socket, :error, message)}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  # Local checkout pages are served by web (live navigation); Stripe pages are external (https only).
  defp go(socket, "//" <> _), do: go(socket, nil)
  defp go(socket, "/" <> _ = path), do: push_navigate(socket, to: path)
  defp go(socket, "https://" <> _ = url), do: redirect(socket, external: url)
  defp go(socket, _url), do: put_flash(socket, :error, Api.error_message({:error, :unavailable}))

  defp update_entitlements(%{} = billing, entitlements),
    do: %{billing | "entitlements" => entitlements}

  defp update_entitlements(other, _entitlements), do: other

  defp web_url, do: Application.fetch_env!(:web, :web_url)

  defp mode(%{mode: mode}, _billing), do: mode
  defp mode(_plans, %{"mode" => mode}), do: mode
  defp mode(_plans, _billing), do: nil

  defp current_plan(%{"entitlements" => %{"plan" => plan, "status" => status}})
       when plan != "free" and status in ["active", "past_due"],
       do: plan

  defp current_plan(%{"entitlements" => _}), do: "free"
  defp current_plan(_billing), do: nil

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
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Your plan")} title={gettext("Membership")}>
          {gettext("Free adventures are always open. Premium unlocks every chapter of the academy.")}
        </.page_header>

        <.payment_mode_banner mode={@mode} />

        <section id="current-plan" class="card space-y-4" aria-labelledby="current-plan-title">
          <h2 id="current-plan-title" class="text-2xl">{gettext("Current plan")}</h2>
          <%= case @billing do %>
            <% :unavailable -> %>
              <.unavailable>{gettext("Your subscription can't be loaded right now.")}</.unavailable>
            <% %{"entitlements" => ent} -> %>
              <div class="flex flex-wrap items-center gap-3">
                <p class="font-display text-4xl text-ink">{plan_name(@plans, ent["plan"])}</p>
                <.tag
                  :if={ent["plan"] != "free"}
                  kind={if ent["status"] == "active", do: "success", else: "danger"}
                  id="subscription-status"
                >
                  {subscription_status_label(ent["status"])}
                </.tag>
              </div>
              <p
                :if={ent["plan"] != "free" and ent["current_period_end"]}
                class="text-muted"
                id="period-end"
              >
                {if ent["cancel_at_period_end"],
                  do:
                    gettext("Ends on %{date}. You keep access until then.",
                      date: date(ent["current_period_end"])
                    ),
                  else: gettext("Renews on %{date}.", date: date(ent["current_period_end"]))}
              </p>
              <p :if={ent["plan"] == "free"} class="text-muted">
                {gettext("You're on the free plan: every free adventure is open to you.")}
              </p>
              <div
                :if={ent["plan"] != "free" and ent["status"] in ["active", "past_due"]}
                class="flex flex-wrap gap-2"
              >
                <.button
                  :if={!ent["cancel_at_period_end"]}
                  phx-click="cancel"
                  variant="ghost"
                  id="cancel-subscription"
                  data-confirm={gettext("Cancel at the end of the current period?")}
                >
                  {gettext("Cancel at period end")}
                </.button>
                <.button
                  :if={ent["cancel_at_period_end"]}
                  phx-click="resume"
                  variant="secondary"
                  id="resume-subscription"
                >
                  {gettext("Resume subscription")}
                </.button>
                <.button
                  :if={@mode == "stripe"}
                  phx-click="portal"
                  variant="secondary"
                  id="billing-portal"
                >
                  <.icon name="hero-credit-card" /> {gettext("Manage billing")}
                </.button>
              </div>
          <% end %>
        </section>

        <section id="ai-credits" class="card space-y-3" aria-labelledby="ai-credits-title">
          <h2 id="ai-credits-title" class="text-2xl">{gettext("AI credits")}</h2>
          <%= case @credits do %>
            <% :unavailable -> %>
              <.unavailable>{gettext("Your AI credits can't be loaded right now.")}</.unavailable>
            <% credits -> %>
              <p class="flex flex-wrap items-baseline gap-x-2">
                <span class="font-display text-4xl text-ink" id="ai-credits-balance">{credits[
                  "balance"
                ]}</span>
                <span class="text-muted">
                  {gettext("of %{allocation} credits left this month",
                    allocation: credits["allocation"]
                  )}
                </span>
              </p>
              <p class="text-sm text-muted">
                {gettext(
                  "Used by the studio's AI assistant. Free 20, Premium 300, VIP 1,000 credits per month; unused credits expire on %{date}.",
                  date: date(credits["resets_at"])
                )}
              </p>
              <.link navigate={~p"/studio/credits"} class="link text-sm" id="ai-credits-history">
                {gettext("Credit history")}
              </.link>
          <% end %>
        </section>

        <section class="space-y-4" aria-labelledby="plans-title">
          <h2 id="plans-title" class="text-3xl">{gettext("Compare plans")}</h2>
          <%= case @plans do %>
            <% :unavailable -> %>
              <.unavailable>{gettext("Plans can't be loaded right now.")}</.unavailable>
            <% plans -> %>
              <div class="grid gap-6 md:grid-cols-3">
                <.plan_card
                  :for={plan <- plans.list}
                  id={"plan-#{plan["key"]}"}
                  plan={plan}
                  current={plan["key"] == @current}
                  extra={extra_features(plan["key"])}
                >
                  <:action>
                    <%= cond do %>
                      <% plan["key"] == @current -> %>
                        <p class="text-sm text-muted">{gettext("This is your plan.")}</p>
                      <% plan["key"] == "free" -> %>
                        <p class="text-sm text-muted">{gettext("Included for every member.")}</p>
                      <% @mode == "disabled" or @current == nil -> %>
                        <.button variant="secondary" class="w-full" disabled>{gettext("Unavailable")}</.button>
                      <% true -> %>
                        <.button
                          phx-click="checkout"
                          phx-value-plan={plan["key"]}
                          variant={if plan["key"] == "premium", do: "reward", else: "primary"}
                          class="w-full"
                          id={"checkout-#{plan["key"]}"}
                          phx-disable-with={gettext("Opening checkout…")}
                        >
                          {if @current == "free",
                            do: gettext("Subscribe"),
                            else:
                              gettext("Switch to %{plan}",
                                plan: MysticWeb.MysticComponents.plan_title(plan)
                              )}
                        </.button>
                    <% end %>
                  </:action>
                </.plan_card>
              </div>
          <% end %>
        </section>

        <section class="space-y-4" aria-labelledby="invoices-title">
          <h2 id="invoices-title" class="text-3xl">{gettext("Invoices")}</h2>
          <%= case @billing do %>
            <% %{"invoices" => [_ | _] = invoices} -> %>
              <div class="table-wrap">
                <table class="data-table" id="invoices">
                  <thead>
                    <tr>
                      <th scope="col">{gettext("Period")}</th>
                      <th scope="col">{gettext("Amount")}</th>
                      <th scope="col">{gettext("Status")}</th>
                      <th scope="col"><span class="sr-only">{gettext("Receipt")}</span></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={invoice <- invoices} id={"invoice-#{invoice["id"]}"}>
                      <td data-label={gettext("Period")}>
                        {date(invoice["period_start"])} – {date(invoice["period_end"])}
                      </td>
                      <td data-label={gettext("Amount")} class="tabular-nums">
                        {money(invoice["amount_cents"], invoice["currency"])}
                      </td>
                      <td data-label={gettext("Status")}>
                        {invoice_status_label(invoice["status"])}
                      </td>
                      <td data-label={gettext("Receipt")}>
                        <a
                          :if={invoice["hosted_url"]}
                          href={invoice["hosted_url"]}
                          class="link"
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          {gettext("View")}<span class="sr-only">{gettext("(opens in a new tab)")}</span>
                        </a>
                        <span :if={!invoice["hosted_url"]} class="text-muted">
                          <span aria-hidden="true">—</span>
                          <span class="sr-only">{gettext("No receipt available")}</span>
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% :unavailable -> %>
              <.unavailable>{gettext("Invoices can't be loaded right now.")}</.unavailable>
            <% _ -> %>
              <p class="text-muted">{gettext("No invoices yet.")}</p>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # Offline copies come with any plan that opens Premium adventures: learning grants them to premium
  # and VIP; VIP's own card already says « Everything in Premium ».
  defp extra_features("premium"),
    do: [
      gettext(
        "Offline reading: premium stories and quizzes kept on your device for up to %{days} days",
        days: MysticWeb.Offline.max_days()
      )
    ]

  defp extra_features(_plan), do: []

  defp plan_name(%{list: plans}, key) do
    Enum.find_value(plans, fn plan ->
      plan["key"] == key && MysticWeb.MysticComponents.plan_title(plan)
    end) || plan_fallback(key)
  end

  defp plan_name(_plans, key), do: plan_fallback(key)

  defp plan_fallback("premium"), do: gettext("Premium")
  defp plan_fallback("vip"), do: gettext("VIP")
  defp plan_fallback(_), do: gettext("Free")
end
