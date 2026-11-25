defmodule MysticWeb.Account.SanctionsLive do
  @moduledoc "The member's own sanctions and the appeal form."
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents, only: [sanction_kind: 1, sanction_status: 1]

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: gettext("Account standing"), appealing: nil) |> load()}

  defp load(socket) do
    case Api.get(socket, :accounts, "/api/me/sanctions") do
      {:ok, %{"sanctions" => sanctions}} -> assign(socket, sanctions: sanctions)
      _ -> assign(socket, sanctions: :unavailable)
    end
  end

  @impl true
  def handle_event("start_appeal", %{"id" => id}, socket),
    do: {:noreply, assign(socket, appealing: id, form: to_form(%{"body" => ""}, as: :appeal))}

  def handle_event("cancel_appeal", _params, socket),
    do: {:noreply, assign(socket, appealing: nil)}

  def handle_event("appeal", %{"appeal" => %{"body" => body}}, socket) do
    case Api.post(socket, :accounts, "/api/me/sanctions/:id/appeal",
           path_params: [id: socket.assigns.appealing],
           json: %{body: body}
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Appeal sent. A staff member who didn't issue the sanction will review it.")
         )
         |> assign(appealing: nil)
         |> load()}

      error ->
        errors = Api.form_errors(error, [:body])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        {:noreply, assign(socket, form: to_form(%{"body" => body}, as: :appeal, errors: errors))}
    end
  end

  @impl true
  def handle_info({:sanction_changed, _user_id}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp appeal_status("open"), do: gettext("Appeal under review")
  defp appeal_status("accepted"), do: gettext("Appeal accepted")
  defp appeal_status(_), do: gettext("Appeal rejected")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:settings}
    >
      <div class="mx-auto max-w-3xl space-y-8">
        <.page_header eyebrow={gettext("Your account")} title={gettext("Account standing")}>
          {gettext("Warnings and restrictions from the moderation team, and your appeals.")}
        </.page_header>
        <%= case @sanctions do %>
          <% :unavailable -> %>
            <.unavailable id="sanctions-unavailable">
              {gettext("Your account standing can't be loaded right now.")}
            </.unavailable>
          <% [] -> %>
            <.empty_state id="sanctions-empty" icon="hero-check-badge" title={gettext("All good")}>
              {gettext("You have no warning and no restriction.")}
            </.empty_state>
          <% sanctions -> %>
            <ul class="space-y-4" id="sanctions">
              <li :for={s <- sanctions} id={"sanction-#{s["id"]}"} class="card space-y-3">
                <p class="flex flex-wrap items-center gap-2">
                  <span class="font-display text-2xl text-ink">{sanction_kind(s["kind"])}</span>
                  <.sanction_status status={s["status"]} />
                </p>
                <p :if={s["ends_at"]} class="text-sm">
                  {if s["status"] == "active",
                    do: gettext("Until %{date}", date: message_time(s["ends_at"])),
                    else: gettext("Ended %{date}", date: message_time(s["ends_at"]))}
                </p>
                <p
                  :if={s["kind"] == "restriction" and s["status"] == "active"}
                  class="text-sm text-muted"
                >
                  {gettext(
                    "Until then you can read, learn and play, but you can't send private messages, post in the forum or write in lobby chats."
                  )}
                </p>
                <p class="whitespace-pre-wrap">{s["reason"]}</p>
                <p class="text-xs text-muted">
                  {gettext("Issued %{date}", date: message_time(s["inserted_at"]))}
                </p>
                <div :if={s["appeal"]} class="notice notice-info" id={"appeal-#{s["id"]}"}>
                  <div class="space-y-1">
                    <p class="font-semibold text-ink">{appeal_status(s["appeal"]["status"])}</p>
                    <p class="whitespace-pre-wrap text-sm">{s["appeal"]["body"]}</p>
                    <p :if={s["appeal"]["decision_reason"]} class="text-sm">
                      {gettext("Decision: %{reason}", reason: s["appeal"]["decision_reason"])}
                    </p>
                  </div>
                </div>
                <%= if s["appealable"] do %>
                  <%= if @appealing == s["id"] do %>
                    <.form for={@form} id="appeal-form" phx-submit="appeal" class="space-y-3">
                      <.input
                        field={@form[:body]}
                        type="textarea"
                        rows="4"
                        maxlength="2000"
                        label={
                          gettext("Why should this sanction be lifted? (10 to 2,000 characters)")
                        }
                        required
                      />
                      <div class="flex flex-wrap gap-2">
                        <.button type="submit" id="send-appeal">{gettext("Send appeal")}</.button>
                        <.button type="button" variant="ghost" phx-click="cancel_appeal">{gettext(
                          "Cancel"
                        )}</.button>
                      </div>
                    </.form>
                  <% else %>
                    <.button
                      phx-click="start_appeal"
                      phx-value-id={s["id"]}
                      variant="secondary"
                      id={"appeal-button-#{s["id"]}"}
                    >
                      <.icon name="hero-scale" /> {gettext("Appeal")}
                    </.button>
                  <% end %>
                <% end %>
              </li>
            </ul>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
