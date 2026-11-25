defmodule MysticWeb.Admin.BillingLive do
  @moduledoc """
  Billing for admins: read-only subscriptions and webhooks, and a manual AI-credit adjustment.
  """
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard

  on_mount {Guard, :admin}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Billing & credits"), ref: new_ref())
     |> assign(form: to_form(%{"username" => "", "amount" => "", "reason" => ""}, as: :credits))
     |> load_events()}
  end

  defp new_ref, do: "admin:" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  @impl true
  def handle_params(params, _uri, socket) do
    case Api.get(socket, :billing, "/api/admin/subscriptions",
           params: [page: params["page"] || "1", status: params["status"] || ""]
         ) do
      {:ok, %{"entries" => entries} = page} ->
        {:noreply,
         assign(socket,
           subscriptions: page,
           status: params["status"] || "",
           names: names(socket, Enum.map(entries, & &1["user_id"]))
         )}

      _ ->
        {:noreply,
         assign(socket, subscriptions: :unavailable, status: params["status"] || "", names: %{})}
    end
  end

  defp load_events(socket) do
    case Api.get(socket, :billing, "/api/admin/webhook-events") do
      {:ok, %{"entries" => _} = page} -> assign(socket, events: page)
      _ -> assign(socket, events: :unavailable)
    end
  end

  # public names of the subscribers (accounts), best effort
  defp names(_socket, []), do: %{}

  defp names(socket, ids) do
    case Api.get(socket, :accounts, "/api/users",
           params: [ids: ids |> Enum.uniq() |> Enum.join(",")]
         ) do
      {:ok, %{"users" => users}} -> Map.new(users, &{&1["id"], &1})
      _ -> %{}
    end
  end

  @impl true
  def handle_event("status", %{"status" => status}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/admin/billing?#{%{status: status}}")}

  def handle_event("adjust", %{"credits" => params}, socket) do
    username = params["username"] |> to_string() |> String.trim() |> String.downcase()

    with {:ok, %{"user" => %{"id" => user_id}}} <-
           Api.get(socket, :accounts, "/api/users/by-username/:username",
             path_params: [username: username]
           ),
         {:ok, %{"adjustment" => adjustment}} <-
           Api.post(socket, :billing, "/api/admin/credits/adjustments",
             json: %{
               user_id: user_id,
               amount: params["amount"],
               reason: params["reason"],
               ref: socket.assigns.ref
             }
           ) do
      message =
        if adjustment["status"] == "duplicate",
          do:
            gettext(
              "Already applied: this adjustment was recorded once, nothing more was credited."
            ),
          else:
            gettext("%{amount} credits granted. New balance: %{balance}.",
              amount: adjustment["amount"],
              balance: adjustment["balance"]
            )

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> assign(
         ref: new_ref(),
         form: to_form(%{"username" => "", "amount" => "", "reason" => ""}, as: :credits)
       )}
    else
      {:error, {:http, 404, _}} ->
        errors = [username: {gettext("No member with this username."), []}]
        {:noreply, assign(socket, form: to_form(params, as: :credits, errors: errors))}

      error ->
        errors = Api.form_errors(error, [:amount, :reason])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        {:noreply, assign(socket, form: to_form(params, as: :credits, errors: errors))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp plan_label("premium"), do: gettext("Premium")
  defp plan_label("vip"), do: gettext("VIP")
  defp plan_label(_), do: gettext("Free")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:billing}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Admins only")} title={gettext("Billing & credits")}>
          {gettext(
            "Subscriptions are read-only here: only signed payment events change a membership."
          )}
        </.page_header>

        <section class="card space-y-4" aria-labelledby="adjust-title" id="credit-adjustment">
          <h2 id="adjust-title" class="text-2xl">{gettext("Grant AI credits")}</h2>
          <p class="text-sm text-muted">
            {gettext(
              "An exceptional allocation for one member (1 to 5,000 credits), with a reason recorded in the audit log. Credits expire at the end of the month like the others."
            )}
          </p>
          <.form for={@form} id="adjust-form" phx-submit="adjust" class="grid gap-4 md:grid-cols-3">
            <.input field={@form[:username]} label={gettext("Member username")} required />
            <.input
              field={@form[:amount]}
              type="number"
              min="1"
              max="5000"
              label={gettext("Credits")}
              required
            />
            <.input field={@form[:reason]} label={gettext("Reason")} required maxlength="500" />
            <div class="md:col-span-3">
              <.button type="submit" id="adjust" phx-disable-with={gettext("Granting…")}>
                {gettext("Grant credits")}
              </.button>
            </div>
          </.form>
        </section>

        <section class="space-y-4" aria-labelledby="subscriptions-title" id="subscriptions-section">
          <div class="flex flex-wrap items-end justify-between gap-3">
            <h2 id="subscriptions-title" class="text-2xl">{gettext("Subscriptions")}</h2>
            <.form for={%{}} id="status-filter" phx-change="status">
              <.input
                name="status"
                id="subscription-status"
                type="select"
                label={gettext("Status")}
                value={@status}
                options={[
                  {gettext("All"), ""},
                  {subscription_status_label("active"), "active"},
                  {subscription_status_label("past_due"), "past_due"},
                  {subscription_status_label("canceled"), "canceled"}
                ]}
              />
            </.form>
          </div>
          <%= case @subscriptions do %>
            <% :unavailable -> %>
              <.unavailable id="subscriptions-unavailable">
                {gettext("Subscriptions can't be loaded right now.")}
              </.unavailable>
            <% %{"entries" => []} -> %>
              <.empty_state
                id="subscriptions-empty"
                icon="hero-credit-card"
                title={gettext("No subscription")}
              />
            <% page -> %>
              <table class="admin-table" id="subscriptions">
                <thead>
                  <tr>
                    <th scope="col">{gettext("Member")}</th>
                    <th scope="col">{gettext("Plan")}</th>
                    <th scope="col">{gettext("Status")}</th>
                    <th scope="col">{gettext("Period ends")}</th>
                    <th scope="col">{gettext("Provider")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={s <- page["entries"]} id={"subscription-#{s["id"]}"}>
                    <td data-label={gettext("Member")}><.person person={@names[s["user_id"]]} /></td>
                    <td data-label={gettext("Plan")}>{plan_label(s["plan"])}</td>
                    <td data-label={gettext("Status")}>
                      <div>
                        {subscription_status_label(s["status"])}
                        <span :if={s["cancel_at_period_end"]} class="block text-xs text-muted">
                          {gettext("Ends at period end")}
                        </span>
                      </div>
                    </td>
                    <td data-label={gettext("Period ends")}>{date(s["current_period_end"])}</td>
                    <td data-label={gettext("Provider")}>{provider_label(s["provider"])}</td>
                  </tr>
                </tbody>
              </table>
              <.pager page={page} path={&~p"/admin/billing?#{%{status: @status, page: &1}}"} />
          <% end %>
        </section>

        <section class="space-y-4" aria-labelledby="events-title" id="failed-events">
          <h2 id="events-title" class="text-2xl">{gettext("Failed webhook events")}</h2>
          <%= case @events do %>
            <% :unavailable -> %>
              <.unavailable id="events-unavailable">
                {gettext("Webhook events can't be loaded right now.")}
              </.unavailable>
            <% %{"entries" => []} -> %>
              <p class="text-sm text-muted" id="events-empty">{gettext("No failed event.")}</p>
            <% page -> %>
              <table class="admin-table" id="events">
                <thead>
                  <tr>
                    <th scope="col">{gettext("Received")}</th>
                    <th scope="col">{gettext("Event")}</th>
                    <th scope="col">{gettext("Error")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={e <- page["entries"]} id={"event-#{e["id"]}"}>
                    <td data-label={gettext("Received")} class="nowrap">
                      {message_time(e["inserted_at"])}
                    </td>
                    <td data-label={gettext("Event")}>
                      <div>
                        <code class="text-sm">{e["type"]}</code>
                        <span class="block text-xs text-muted">{e["provider"]} · {e[
                          "provider_event_id"
                        ]}</span>
                      </div>
                    </td>
                    <td data-label={gettext("Error")}>{e["error"]}</td>
                  </tr>
                </tbody>
              </table>
          <% end %>
        </section>
      </div>
    </Layouts.admin>
    """
  end

  # payment provider of a subscription: the simulated local mode is named in the page's language
  defp provider_label("local"), do: gettext("Simulated (local)")
  defp provider_label("stripe"), do: "Stripe"
  defp provider_label(provider), do: provider
end
