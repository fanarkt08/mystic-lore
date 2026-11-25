defmodule MysticWeb.PrivacyComponents do
  @moduledoc "« Your data » blocks: the scheduled-deletion banner and the exports and deletion section."
  use MysticWeb, :html

  @doc "Shown while a deletion is scheduled (`deletion_scheduled_at` of the private member)."
  attr :user, :map, required: true

  def deletion_banner(assigns) do
    ~H"""
    <.notice
      :if={@user["deletion_scheduled_at"]}
      id="deletion-banner"
      kind="warning"
      role="alert"
      title={gettext("Your account is scheduled for deletion")}
    >
      {gettext(
        "It will be deleted on %{date}. Until then everything keeps working and you can change your mind.",
        date: date(@user["deletion_scheduled_at"])
      )}
      <:actions>
        <.button id="cancel-deletion" variant="secondary" phx-click="cancel_deletion">
          <.icon name="hero-arrow-uturn-left" /> {gettext("Cancel deletion")}
        </.button>
      </:actions>
    </.notice>
    """
  end

  @doc "Settings section: export requests and their status, then account deletion."
  attr :user, :map, required: true
  attr :exports, :any, required: true, doc: "list of exports, or :unavailable"
  attr :export_form, Phoenix.HTML.Form, required: true
  attr :deletion_form, Phoenix.HTML.Form, required: true

  def your_data(assigns) do
    ~H"""
    <section class="card space-y-8" id="your-data" aria-labelledby="your-data-title">
      <div class="space-y-1">
        <h2 id="your-data-title" class="text-2xl">{gettext("Your data")}</h2>
        <p class="text-sm text-muted">
          {gettext("Download a copy of what MysticLore holds about you, or delete your account.")}
        </p>
      </div>

      <div class="space-y-4" id="data-export">
        <h3 class="font-semibold text-ink">{gettext("Download your data")}</h3>
        <p class="text-sm text-muted">
          {gettext(
            "One JSON file with your profile, sessions, learning progress, notes, XP and badges, friends and the messages you sent, forum posts, games, studio projects and AI generations, subscription, invoices and AI credits. It is prepared in the background, usually within a minute, and can be downloaded for 24 hours. Up to 3 requests per day."
          )}
        </p>
        <.form for={@export_form} id="export-form" phx-submit="request_export" class="space-y-3">
          <.input
            field={@export_form[:password]}
            type="password"
            label={gettext("Current password")}
            autocomplete="current-password"
            required
          />
          <.button type="submit" id="request-export" phx-disable-with={gettext("Requesting…")}>
            <.icon name="hero-arrow-down-tray" /> {gettext("Prepare my data")}
          </.button>
        </.form>

        <div class="flex flex-wrap items-center justify-between gap-2">
          <h4 class="text-sm font-semibold text-ink">{gettext("Your exports")}</h4>
          <.button id="refresh-exports" variant="ghost" phx-click="refresh_exports">
            <.icon name="hero-arrow-path" /> {gettext("Refresh")}
          </.button>
        </div>
        <%= case @exports do %>
          <% :unavailable -> %>
            <.unavailable id="exports-unavailable">
              {gettext("Your exports can't be listed.")}
            </.unavailable>
          <% [] -> %>
            <p id="no-exports" class="text-sm text-muted">{gettext("No export requested yet.")}</p>
          <% exports -> %>
            <ul id="export-list" class="divide-y divide-line">
              <li
                :for={export <- exports}
                id={"export-#{export["id"]}"}
                class="flex flex-wrap items-center justify-between gap-3 py-3"
              >
                <div class="min-w-0 space-y-1">
                  <p class="flex flex-wrap items-center gap-2 font-medium text-ink">
                    {gettext("Requested %{time}", time: message_time(export["inserted_at"]))}
                    <.export_status status={export["status"]} />
                  </p>
                  <p class="text-sm text-muted">{export_detail(export)}</p>
                </div>
                <.button
                  :if={export["status"] == "ready"}
                  id={"download-#{export["id"]}"}
                  href={~p"/settings/exports/#{export["id"]}/download"}
                  variant="secondary"
                >
                  <.icon name="hero-document-arrow-down" /> {gettext("Download (JSON)")}
                </.button>
              </li>
            </ul>
        <% end %>
      </div>

      <div :if={!@user["deletion_scheduled_at"]} class="space-y-4" id="account-deletion">
        <h3 class="font-semibold text-ink">{gettext("Delete my account")}</h3>
        <p class="text-sm text-muted">
          {gettext(
            "Your account is not deleted right away: you are signed out everywhere, we e-mail you the date, and until that date you can log in again and cancel."
          )}
        </p>
        <dl class="space-y-3 text-sm">
          <div>
            <dt class="font-semibold text-ink">{gettext("Deleted")}</dt>
            <dd class="text-muted">
              {gettext(
                "Your e-mail, password, profile and two-factor settings; learning progress, notes, XP and badges; friends, friend requests and blocks; forum subscriptions; multiplayer invitations and links; AI settings and generations; studio projects nobody else works on."
              )}
            </dd>
          </div>
          <div>
            <dt class="font-semibold text-ink">{gettext("Kept, shown as “Deleted member”")}</dt>
            <dd class="text-muted">
              {gettext(
                "The messages you sent, your forum discussions, replies and votes, your game history, and the studio projects you share with collaborators or have published (the published adventures stay in the catalogue, without author)."
              )}
            </dd>
          </div>
          <div>
            <dt class="font-semibold text-ink">{gettext("Billing")}</dt>
            <dd class="text-muted">
              {gettext(
                "Your subscription is cancelled at once, so you are never charged again. Invoices and the AI credit ledger are kept without personal data, as accounting law requires. Reports and moderation records are kept too."
              )}
            </dd>
          </div>
        </dl>
        <.form
          for={@deletion_form}
          id="deletion-form"
          phx-submit="delete_account"
          class="space-y-3"
        >
          <.input
            field={@deletion_form[:password]}
            type="password"
            label={gettext("Current password")}
            autocomplete="current-password"
            required
          />
          <.input
            field={@deletion_form[:confirm_username]}
            label={
              gettext("Type your username, %{username}, to confirm", username: @user["username"])
            }
            autocomplete="off"
            autocapitalize="none"
            spellcheck="false"
            required
          />
          <.button
            type="submit"
            id="delete-account"
            variant="danger"
            phx-disable-with={gettext("Scheduling…")}
          >
            <.icon name="hero-trash" /> {gettext("Delete my account")}
          </.button>
        </.form>
      </div>
    </section>
    """
  end

  attr :status, :string, required: true

  defp export_status(assigns) do
    ~H"""
    <%= case @status do %>
      <% "ready" -> %>
        <.tag kind="success" icon="hero-check-circle">{gettext("Ready")}</.tag>
      <% "failed" -> %>
        <.tag kind="danger">{gettext("Failed")}</.tag>
      <% "expired" -> %>
        <.tag>{gettext("Expired")}</.tag>
      <% _pending -> %>
        <.tag kind="info" icon="hero-arrow-path">{gettext("Preparing…")}</.tag>
    <% end %>
    """
  end

  defp export_detail(%{"status" => "ready", "expires_at" => at}),
    do: gettext("Available until %{time}.", time: message_time(at))

  defp export_detail(%{"status" => "failed", "failed_services" => services}),
    do:
      gettext("Some services didn't answer (%{services}). Please request a new export later.",
        services: services_label(services)
      )

  defp export_detail(%{"status" => "expired"}),
    do: gettext("No longer available: request a new export.")

  defp export_detail(%{"failed_services" => [_ | _] = services}),
    do:
      gettext("Waiting for %{services}: retrying automatically.",
        services: services_label(services)
      )

  defp export_detail(_pending), do: gettext("This page updates by itself when it is ready.")

  defp services_label(services), do: Enum.map_join(List.wrap(services), ", ", &service_label/1)

  defp service_label("learning"), do: gettext("learning")
  defp service_label("billing"), do: gettext("membership")
  defp service_label("social"), do: gettext("friends and messages")
  defp service_label("multiplayer"), do: gettext("multiplayer")
  defp service_label("community"), do: gettext("community")
  defp service_label("studio"), do: gettext("studio")
  defp service_label(other), do: to_string(other)
end
