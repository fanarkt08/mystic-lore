defmodule MysticWeb.OfflineComponents do
  @moduledoc """
  Offline lesson blocks filled by `assets/js/offline.js`, with every text translated here.
  """
  use MysticWeb, :html
  alias MysticWeb.{Format, Offline}

  attr :lesson, :map, required: true
  attr :slug, :string, required: true
  attr :offline, :map, required: true

  def lesson_card(assigns) do
    assigns =
      assign(assigns,
        id: assigns.lesson["id"],
        days: assigns.offline["max_days"] || Offline.max_days(),
        texts: Jason.encode!(Offline.texts(:lesson))
      )

    ~H"""
    <section
      id={"offline-copy-#{@id}"}
      class="card offline-card"
      aria-labelledby={"offline-copy-title-#{@id}"}
      phx-hook="OfflineLesson"
      phx-update="ignore"
      data-lesson-id={@id}
      data-revision={@offline["revision"]}
      data-title={@lesson["title"]}
      data-locale={Gettext.get_locale(MysticWeb.Gettext)}
      data-time-zone={Format.time_zone()}
      data-texts={@texts}
    >
      <div class="offline-card-head">
        <span class="offline-card-icon" aria-hidden="true">
          <.icon name="hero-cloud-arrow-down" class="size-6" />
        </span>
        <div class="min-w-0 space-y-1">
          <h2 id={"offline-copy-title-#{@id}"} class="text-2xl">{gettext("Offline copy")}</h2>
          <p class="text-sm text-muted">
            {gettext(
              "Keep this lesson on this device to read it and answer without a connection: %{days} days at most, and never after the end of your paid period.",
              days: @days
            )}
          </p>
        </div>
      </div>
      <ul class="offline-facts">
        <li>
          {gettext(
            "Answers given offline wait on this device: the server checks them when you're back online, and they count on the day they are synchronized."
          )}
        </li>
        <li>
          {gettext(
            "Anyone using this device can read the copy: it isn't protected against copying. Logging out deletes it."
          )}
        </li>
      </ul>
      <p id="offline-copy-status" class="text-sm" role="status" aria-live="polite"></p>
      <div class="flex flex-wrap gap-2">
        <button type="button" id="offline-download" class="btn btn-secondary" disabled>
          <.icon name="hero-cloud-arrow-down" />
          <span data-label>{gettext("Make available offline")}</span>
        </button>
        <a id="offline-open" href={~p"/offline?#{[lesson: @id]}"} class="btn btn-ghost" hidden>
          <.icon name="hero-book-open" /> {gettext("Open the offline copy")}
        </a>
        <button type="button" id="offline-remove" class="btn btn-ghost" hidden>
          <.icon name="hero-trash" /> {gettext("Remove from this device")}
        </button>
      </div>
      <noscript>
        <p class="text-sm text-muted">{gettext("Offline copies need JavaScript in this browser.")}</p>
      </noscript>
    </section>
    """
  end

  def settings_section(assigns) do
    assigns =
      assign(assigns,
        days: Offline.max_days(),
        texts: Jason.encode!(Offline.texts(:settings))
      )

    ~H"""
    <section
      id="offline-settings"
      class="card space-y-5"
      aria-labelledby="offline-settings-title"
      phx-hook="OfflineSettings"
      phx-update="ignore"
      data-locale={Gettext.get_locale(MysticWeb.Gettext)}
      data-time-zone={Format.time_zone()}
      data-texts={@texts}
    >
      <div class="space-y-2">
        <h2 id="offline-settings-title" class="text-2xl">{gettext("Offline lessons")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "With a Premium or VIP membership, the stories and quizzes of Premium adventures can be kept on this device from their lesson page (« Make available offline »), for %{days} days at most and never after the end of your paid period.",
            days: @days
          )}
        </p>
        <p class="text-sm text-muted">
          {gettext(
            "Offline, answers wait on this device and are never marked right or wrong there: the server checks them when you're back online, and they count on the day they are synchronized. A copy sits on the device unprotected (anyone using it can read it) and a device that never reconnects keeps it until it expires. Logging out, another member logging in on this device, the end of your Premium access and the button below delete it."
          )}
        </p>
      </div>

      <p
        id="offline-summary"
        class="font-medium text-ink"
        role="status"
        aria-live="polite"
        tabindex="-1"
      >
      </p>
      <ul id="offline-packages" class="offline-list"></ul>

      <div class="offline-sync">
        <div class="min-w-0 flex-1 space-y-1">
          <p id="offline-sync-status" class="text-sm" role="status" aria-live="polite"></p>
          <p id="offline-sync-reason" class="text-sm text-muted"></p>
        </div>
        <button
          type="button"
          id="offline-sync-now"
          class="btn btn-secondary"
          aria-describedby="offline-sync-reason"
          disabled
        >
          <.icon name="hero-arrow-path" />
          <span data-label>{gettext("Synchronize now")}</span>
        </button>
      </div>

      <div id="offline-results" class="space-y-2" hidden>
        <h3 class="text-xl">{gettext("Last synchronization")}</h3>
        <ul id="offline-results-list" class="offline-results"></ul>
      </div>

      <div class="flex flex-wrap gap-2 border-t border-line pt-4">
        <a href={~p"/offline"} class="btn btn-ghost" id="offline-open-shell">
          <.icon name="hero-book-open" /> {gettext("Open the offline page")}
        </a>
        <button type="button" id="offline-clear" class="btn btn-danger" disabled>
          <.icon name="hero-trash" /> <span data-label>{gettext("Clear offline data")}</span>
        </button>
      </div>
      <noscript>
        <p class="text-sm text-muted">{gettext("Offline copies need JavaScript in this browser.")}</p>
      </noscript>
    </section>
    """
  end

  attr :member, :map, default: nil

  def offline_notice(assigns) do
    ~H"""
    <div
      id="offline-notice"
      class="offline-notice"
      role="status"
      aria-live="polite"
      phx-update="ignore"
      data-member={@member && @member["id"]}
      data-generic={MysticWeb.Offline.ended_message(nil)}
      hidden
    >
      <.icon name="hero-cloud-arrow-down" class="size-5 shrink-0" />
      <p id="offline-notice-text" class="min-w-0 flex-1 text-sm font-medium"></p>
      <.link navigate={~p"/membership"} class="btn btn-secondary" id="offline-notice-renew">
        {gettext("Renew my membership")}
      </.link>
      <button
        type="button"
        class="toast-close"
        id="offline-notice-close"
        aria-label={gettext("Dismiss")}
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </div>
    """
  end
end
