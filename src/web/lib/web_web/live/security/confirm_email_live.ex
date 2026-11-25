defmodule MysticWeb.Security.ConfirmEmailLive do
  @moduledoc "Confirms an e-mail change with a button, so that link scanners can't apply it."
  use MysticWeb, :live_view

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     assign(socket, page_title: gettext("Confirm your new email"), token: token, state: :pending)}
  end

  @impl true
  def handle_event("confirm", _params, socket) do
    case Api.post(socket, :accounts, "/api/me/email/confirm",
           json: %{token: socket.assigns.token}
         ) do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        {:noreply, assign(socket, current_user: user, state: :confirmed)}

      {:error, {:http, 404, _}} ->
        {:noreply, assign(socket, state: :invalid)}

      {:error, {:http, 422, _}} ->
        {:noreply, assign(socket, state: :taken)}

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
      active={:settings}
    >
      <div class="max-w-2xl space-y-8">
        <.page_header eyebrow={gettext("Your account")} title={gettext("Confirm your new email")} />

        <section id="confirm-email" class="card space-y-5">
          <%= case @state do %>
            <% :pending -> %>
              <p class="text-muted">
                {gettext(
                  "Confirm that this address belongs to you: it will replace %{email} for logging in and for our emails.",
                  email: @current_user["email"]
                )}
              </p>
              <.button
                id="confirm-email-button"
                phx-click="confirm"
                phx-disable-with={gettext("Confirming…")}
              >
                {gettext("Use my new email address")}
              </.button>
            <% :confirmed -> %>
              <.notice kind="success" title={gettext("Email address changed")}>
                {gettext("From now on, log in with %{email}.", email: @current_user["email"])}
              </.notice>
              <.button navigate={~p"/settings"} variant="secondary">{gettext("Back to settings")}</.button>
            <% :invalid -> %>
              <.access_state
                id="confirm-email-invalid"
                icon="hero-link-slash"
                title={gettext("This link can't be used")}
                live
              >
                {gettext(
                  "It is invalid, has expired (links last 24 hours), was already used, or was requested from another account. Ask for a new one from your settings."
                )}
                <:actions>
                  <.button navigate={~p"/settings/account"} variant="secondary">
                    {gettext("Ask for a new link")}
                  </.button>
                </:actions>
              </.access_state>
            <% :taken -> %>
              <.notice kind="warning" role="alert" title={gettext("Address no longer available")}>
                {gettext(
                  "Another account started using this address in the meantime. Your email address hasn't changed."
                )}
              </.notice>
              <.button navigate={~p"/settings"} variant="secondary">{gettext("Back to settings")}</.button>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
