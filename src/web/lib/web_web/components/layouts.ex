defmodule MysticWeb.Layouts do
  @moduledoc "Page shells: the member shell when a user is signed in, the public shell otherwise."
  use MysticWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  attr :unread, :map, default: nil, doc: "social `GET /api/me/unread` counters"

  attr :notifications, :map,
    default: nil,
    doc: "bell count and toast of the notification center (`MysticWeb.Auth`)"

  attr :active, :atom, default: nil, doc: "current navigation entry"
  attr :bleed, :boolean, default: false, doc: "full-width content (landing sections)"

  attr :current_path, :string,
    default: nil,
    doc: "page to come back to after choosing a language (visitors)"

  slot :inner_block, required: true

  def app(%{current_user: nil} = assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col">
      <.public_header active={@active} />
      <main id="main" class={["flex-1", !@bleed && "page"]}>{render_slot(@inner_block)}</main>
      <.public_footer current_path={@current_path} />
    </div>
    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    assigns = assign(assigns, :items, nav_items(assigns.unread, assigns.current_user))

    ~H"""
    <div class="member-shell">
      <aside class="rail" aria-label={gettext("Application")}>
        <.link navigate={~p"/dashboard"} class="rail-brand">
          <.brand_mark />
          <span class="rail-label font-display text-2xl text-ink">MysticLore</span>
        </.link>
        <nav aria-label={gettext("Main")} class="rail-nav">
          <.bell
            id="nav-notifications"
            notifications={@notifications}
            active={@active == :notifications}
            label
          />
          <.nav_link :for={item <- @items} id={"nav-#{item.key}"} item={item} active={@active} />
        </nav>
        <div class="rail-footer">
          <nav aria-label={gettext("Help and legal information")} class="rail-help">
            <.link navigate={~p"/help"} class="nav-link" id="rail-help">
              <.icon name="hero-lifebuoy" />
              <span class="rail-label">{gettext("Help & contact")}</span>
            </.link>
            <.link navigate={~p"/legal"} class="nav-link" id="rail-legal">
              <.icon name="hero-document-text" />
              <span class="rail-label">{gettext("Legal")}</span>
            </.link>
          </nav>
          <div class="rail-user">
            <.avatar user={@current_user} size="sm" />
            <div class="rail-label min-w-0">
              <p class="break-words text-sm font-medium text-ink">{@current_user["display_name"]}</p>
              <p class="break-words text-xs text-muted">@{@current_user["username"]}</p>
            </div>
          </div>
          <.link href={~p"/logout"} method="delete" class="nav-link" id="rail-logout">
            <.icon name="hero-arrow-left-start-on-rectangle" />
            <span class="rail-label">{gettext("Log out")}</span>
          </.link>
        </div>
      </aside>

      <div class="member-main">
        <header class="mobile-header">
          <.link navigate={~p"/dashboard"} class="mobile-brand">
            <.brand_mark />
            <span class="truncate font-display text-2xl text-ink">MysticLore</span>
          </.link>
          <div class="mobile-header-actions">
            <.bell
              id="mobile-bell"
              notifications={@notifications}
              active={@active == :notifications}
            />
            <.link navigate={~p"/settings"} class="mobile-settings">
              <span class="sr-only">{gettext("Settings")}</span>
              <.avatar user={@current_user} size="sm" />
            </.link>
          </div>
        </header>
        <main id="main" class={[!@bleed && "page"]}>{render_slot(@inner_block)}</main>
      </div>

      <nav aria-label={gettext("Main")} class="mobile-nav">
        <.link
          :for={item <- Enum.take(@items, 4)}
          navigate={item.path}
          class="mobile-nav-link"
          aria-current={@active == item.key && "page"}
        >
          <span class="relative">
            <.icon name={item.icon} class="size-6" />
            <.count_badge count={item.badge} label={item.badge_label} class="count-badge-dot" />
          </span>
          <span>{item.label}</span>
        </.link>
        <button type="button" popovertarget="more-menu" class="mobile-nav-link">
          <.icon name="hero-ellipsis-horizontal-circle" class="size-6" />
          <span>{gettext("More")}</span>
        </button>
      </nav>
      <nav id="more-menu" popover class="more-menu" aria-label={gettext("More")}>
        <.nav_link
          :for={item <- Enum.drop(@items, 4)}
          id={"more-#{item.key}"}
          item={item}
          active={@active}
        />
        <.link navigate={~p"/help"} class="nav-link" id="more-help">
          <.icon name="hero-lifebuoy" />
          <span>{gettext("Help center")}</span>
        </.link>
        <.link navigate={~p"/contact"} class="nav-link" id="more-contact">
          <.icon name="hero-envelope" />
          <span>{gettext("Contact us")}</span>
        </.link>
        <.link navigate={~p"/legal"} class="nav-link" id="more-legal">
          <.icon name="hero-document-text" />
          <span>{gettext("Legal")}</span>
        </.link>
        <.link href={~p"/logout"} method="delete" class="nav-link">
          <.icon name="hero-arrow-left-start-on-rectangle" />
          <span>{gettext("Log out")}</span>
        </.link>
      </nav>

      <p class="sr-only" aria-live="polite" id="unread-status">
        <%= if is_integer(@unread["messages"]) and @unread["messages"] > 0 do %>
          {ngettext("%{count} unread message", "%{count} unread messages", @unread["messages"])}
        <% end %>
      </p>
    </div>
    <.flash_group flash={@flash} member={@current_user} />
    <.notification_toast notifications={@notifications} />
    """
  end

  @doc "Notification bell with the live unread count."
  attr :id, :string, required: true
  attr :notifications, :map, default: nil
  attr :active, :boolean, default: false
  attr :label, :boolean, default: false
  attr :class, :string, default: nil

  def bell(assigns) do
    assigns = assign(assigns, :count, assigns.notifications && assigns.notifications[:unread])

    ~H"""
    <.link
      navigate={~p"/notifications"}
      id={@id}
      class={[if(@label, do: "nav-link", else: "bell-button"), @class]}
      aria-label={bell_label(@count)}
      aria-current={@active && "page"}
    >
      <span class="relative">
        <.icon name="hero-bell" class={if @label, do: "size-5", else: "size-6"} />
        <.count_badge
          count={@count}
          label=""
          class={["count-badge-dot", @label && "rail-dot"]}
          aria-hidden="true"
        />
      </span>
      <span :if={@label} class="rail-label flex-1">{gettext("Notifications")}</span>
      <.count_badge :if={@label} count={@count} label="" class="rail-label" aria-hidden="true" />
    </.link>
    """
  end

  defp bell_label(nil), do: gettext("Notifications (count unavailable)")
  defp bell_label(0), do: gettext("Notifications, none unread")

  defp bell_label(count),
    do: ngettext("Notifications, %{count} unread", "Notifications, %{count} unread", count)

  @doc "Toast of a new notification, in a polite live region that is always in the page."
  attr :notifications, :map, default: nil

  def notification_toast(assigns) do
    assigns = assign(assigns, :toast, assigns.notifications && assigns.notifications[:toast])

    ~H"""
    <div id="notification-toasts" class="notification-toasts" aria-live="polite" aria-atomic="true">
      <div :if={@toast} id="notification-toast" class="notification-toast">
        <span class="notification-toast-icon">
          <.icon name={MysticWeb.Notifications.icon(@toast)} class="size-5" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-xs font-medium text-muted">{gettext("New notification")}</p>
          <.link
            navigate={~p"/notifications?#{[open: @toast["id"]]}"}
            id="notification-toast-link"
            class="notification-toast-link"
          >
            {MysticWeb.Notifications.text(@toast)}
          </.link>
        </div>
        <button
          type="button"
          class="toast-close"
          id="notification-toast-close"
          phx-click="dismiss-notification-toast"
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  defp nav_items(unread, user) do
    unread = unread || %{}

    [
      %{key: :dashboard, path: ~p"/dashboard", icon: "hero-home", label: gettext("Dashboard")},
      %{key: :adventures, path: ~p"/adventures", icon: "hero-map", label: gettext("Adventures")},
      %{
        key: :friends,
        path: ~p"/friends",
        icon: "hero-user-group",
        label: gettext("Friends"),
        badge: unread["friend_requests"],
        badge_label: gettext("pending friend requests")
      },
      %{
        key: :messages,
        path: ~p"/messages",
        icon: "hero-chat-bubble-left-right",
        label: gettext("Messages"),
        badge: unread["messages"],
        badge_label: gettext("unread messages")
      },
      %{
        key: :multiplayer,
        path: ~p"/multiplayer",
        icon: "hero-puzzle-piece",
        label: gettext("Multiplayer")
      },
      %{
        key: :community,
        path: ~p"/community",
        icon: "hero-chat-bubble-bottom-center-text",
        label: gettext("Community")
      },
      %{
        key: :achievements,
        path: ~p"/achievements",
        icon: "hero-trophy",
        label: gettext("Achievements")
      },
      %{key: :studio, path: ~p"/studio", icon: "hero-pencil-square", label: gettext("Studio")},
      %{
        key: :membership,
        path: ~p"/membership",
        icon: "hero-sparkles",
        label: gettext("Membership")
      },
      %{key: :settings, path: ~p"/settings", icon: "hero-cog-6-tooth", label: gettext("Settings")}
    ]
    # staff only (the /admin pages and every service check the role again)
    |> Kernel.++(
      if MysticWeb.Admin.Guard.staff?(user),
        do: [
          %{
            key: :admin,
            path: ~p"/admin",
            icon: "hero-shield-check",
            label: gettext("Administration")
          }
        ],
        else: []
    )
    |> Enum.map(&Map.merge(%{badge: nil, badge_label: ""}, &1))
  end

  @doc """
  Staff shell of the `/admin` pages: dark rail (keyboard: arrow keys, Home, End; a skip link jumps to the
  content), sections filtered by role (audit log and billing for admins only).
  """
  attr :flash, :map, required: true
  attr :current_user, :map, required: true
  attr :active, :atom, required: true
  attr :notifications, :map, default: nil, doc: "bell count and toast (`MysticWeb.Auth`)"
  slot :inner_block, required: true

  def admin(assigns) do
    assigns = assign(assigns, :items, admin_items(assigns.current_user))

    ~H"""
    <div class="admin-shell">
      <aside class="admin-rail" aria-label={gettext("Administration")}>
        <div class="admin-rail-brand">
          <.brand_mark />
          <div class="min-w-0">
            <p class="font-display text-xl text-ink">{gettext("Administration")}</p>
            <p class="break-words text-xs text-muted">
              @{@current_user["username"]} · {MysticWeb.AdminComponents.role_label(
                @current_user["role"]
              )}
            </p>
          </div>
        </div>
        <nav
          id="admin-nav"
          aria-label={gettext("Administration sections")}
          class="admin-nav"
          phx-hook=".AdminRail"
        >
          <.link
            :for={item <- @items}
            id={"admin-nav-#{item.key}"}
            navigate={item.path}
            class="admin-link"
            aria-current={@active == item.key && "page"}
          >
            <.icon name={item.icon} />
            <span>{item.label}</span>
          </.link>
        </nav>
        <.bell id="admin-bell" notifications={@notifications} class="admin-link admin-bell" />
        <.link navigate={~p"/help"} class="admin-link" id="admin-help">
          <.icon name="hero-lifebuoy" />
          <span>{gettext("Help & contact")}</span>
        </.link>
        <.link navigate={~p"/dashboard"} class="admin-link admin-exit" id="admin-exit">
          <.icon name="hero-arrow-uturn-left" />
          <span>{gettext("Back to MysticLore")}</span>
        </.link>
      </aside>
      <main id="main" class="admin-main" tabindex="-1">
        <div class="admin-page">{render_slot(@inner_block)}</div>
      </main>
    </div>
    <.flash_group flash={@flash} member={@current_user} />
    <.notification_toast notifications={@notifications} />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AdminRail">
      export default {
        mounted() {
          this.el.addEventListener("keydown", (e) => {
            const links = [...this.el.querySelectorAll("a")]
            const i = links.indexOf(document.activeElement)
            if (i < 0) return
            const next = { ArrowDown: i + 1, ArrowRight: i + 1, ArrowUp: i - 1, ArrowLeft: i - 1, Home: 0, End: links.length - 1 }[e.key]
            if (next === undefined) return
            e.preventDefault()
            links[(next + links.length) % links.length].focus()
          })
        }
      }
    </script>
    """
  end

  defp admin_items(user) do
    staff = [
      %{key: :overview, path: ~p"/admin", icon: "hero-chart-bar", label: gettext("Overview")},
      %{key: :reports, path: ~p"/admin/reports", icon: "hero-flag", label: gettext("Reports")},
      %{key: :members, path: ~p"/admin/members", icon: "hero-users", label: gettext("Members")},
      %{
        key: :appeals,
        path: ~p"/admin/sanctions-appeals",
        icon: "hero-scale",
        label: gettext("Sanctions & appeals")
      },
      %{
        key: :incidents,
        path: ~p"/admin/incidents",
        icon: "hero-exclamation-triangle",
        label: gettext("Incidents")
      },
      %{
        key: :support,
        path: ~p"/admin/support",
        icon: "hero-lifebuoy",
        label: gettext("Support")
      },
      %{
        key: :review,
        path: ~p"/studio/review",
        icon: "hero-pencil-square",
        label: gettext("Studio review queue")
      }
    ]

    admin = [
      %{
        key: :audit,
        path: ~p"/admin/audit",
        icon: "hero-document-text",
        label: gettext("Audit log")
      },
      %{
        key: :billing,
        path: ~p"/admin/billing",
        icon: "hero-credit-card",
        label: gettext("Billing & credits")
      }
    ]

    if MysticWeb.Admin.Guard.admin?(user), do: staff ++ admin, else: staff
  end

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :active, :atom, default: nil

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@item.path}
      class="nav-link"
      id={@id}
      aria-current={@active == @item.key && "page"}
    >
      <span class="relative">
        <.icon name={@item.icon} />
        <.count_badge
          count={@item.badge}
          label={@item.badge_label}
          class="count-badge-dot rail-dot"
          aria-hidden="true"
        />
      </span>
      <span class="rail-label flex-1">{@item.label}</span>
      <.count_badge count={@item.badge} label={@item.badge_label} class="rail-label" />
    </.link>
    """
  end

  attr :active, :atom, default: nil

  defp public_header(assigns) do
    ~H"""
    <header class="public-header">
      <div class="container-wide flex h-18 items-center justify-between gap-3">
        <.link navigate={~p"/"} class="flex items-center gap-2">
          <.brand_mark />
          <span class="public-brand-name font-display text-2xl text-ink">MysticLore</span>
        </.link>
        <nav aria-label={gettext("Main")} class="flex items-center gap-1 sm:gap-2">
          <.link
            navigate={~p"/adventures"}
            class="nav-pill hidden sm:inline-flex"
            aria-current={@active == :adventures && "page"}
          >
            {gettext("Adventures")}
          </.link>
          <.link
            navigate={~p"/community"}
            class="nav-pill hidden sm:inline-flex"
            aria-current={@active == :community && "page"}
          >
            {gettext("Community")}
          </.link>
          <a href="/#offers" class="nav-pill hidden lg:inline-flex">{gettext("Membership")}</a>
          <.link href={~p"/login"} class="btn btn-ghost">{gettext("Log in")}</.link>
          <.link href={~p"/register"} class="btn btn-primary">{gettext("Join")}</.link>
        </nav>
      </div>
    </header>
    """
  end

  attr :current_path, :string, default: nil

  # Visitors choose the language here (`POST /locale`, cookie `ml_locale`); members do it in their settings.
  defp public_footer(assigns) do
    assigns = assign(assigns, :locale, Gettext.get_locale(MysticWeb.Gettext))

    ~H"""
    <footer class="public-footer">
      <div class="container-wide grid gap-10 py-16 sm:grid-cols-2 lg:grid-cols-[2fr_1fr_1fr_1fr]">
        <div class="max-w-sm space-y-4">
          <p class="flex items-center gap-2">
            <.brand_mark />
            <span class="font-display text-2xl text-ink">MysticLore</span>
          </p>
          <p class="text-sm text-muted">
            {gettext("An enchanted academy where every lesson is a chapter of your own adventure.")}
          </p>
          <p class="demo-note">
            {gettext("Demo project — all members, adventures and payments are fictional.")}
          </p>
        </div>
        <nav aria-labelledby="footer-explore">
          <h2 id="footer-explore" class="footer-title">{gettext("Explore")}</h2>
          <ul class="space-y-1">
            <li>
              <.link navigate={~p"/adventures"} class="footer-link">{gettext("Adventures")}</.link>
            </li>
            <li>
              <.link navigate={~p"/community"} class="footer-link">{gettext("Community")}</.link>
            </li>
            <li><a href="/#offers" class="footer-link">{gettext("Membership")}</a></li>
            <li><a href="/#faq" class="footer-link">{gettext("FAQ")}</a></li>
          </ul>
        </nav>
        <nav aria-labelledby="footer-account">
          <h2 id="footer-account" class="footer-title">{gettext("Account")}</h2>
          <ul class="space-y-1">
            <li><.link href={~p"/login"} class="footer-link">{gettext("Log in")}</.link></li>
            <li>
              <.link href={~p"/register"} class="footer-link">{gettext("Create an account")}</.link>
            </li>
          </ul>
        </nav>
        <nav aria-labelledby="footer-help">
          <h2 id="footer-help" class="footer-title">{gettext("Help and legal")}</h2>
          <ul class="space-y-1">
            <li>
              <.link navigate={~p"/help"} class="footer-link" id="footer-help-link">
                {gettext("Help center")}
              </.link>
            </li>
            <li>
              <.link navigate={~p"/contact"} class="footer-link" id="footer-contact-link">
                {gettext("Contact us")}
              </.link>
            </li>
            <li>
              <.link navigate={~p"/legal/privacy"} class="footer-link" id="footer-privacy-link">
                {gettext("Privacy notice")}
              </.link>
            </li>
            <li>
              <.link navigate={~p"/legal/terms"} class="footer-link" id="footer-terms-link">
                {gettext("Terms of use")}
              </.link>
            </li>
            <li>
              <.link navigate={~p"/legal/cookies"} class="footer-link" id="footer-cookies-link">
                {gettext("Cookies")}
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/legal/accessibility"}
                class="footer-link"
                id="footer-accessibility-link"
              >
                {gettext("Accessibility")}
              </.link>
            </li>
          </ul>
        </nav>
      </div>
      <div class="container-wide flex flex-wrap items-center justify-between gap-4 border-t border-line py-6 text-sm text-muted">
        <p>{gettext("© 2026 MysticLore · A fictional academy built for demonstration.")}</p>
        <.form
          for={%{}}
          action={~p"/locale"}
          id="locale-form"
          class="flex flex-wrap items-center gap-2"
        >
          <input :if={@current_path} type="hidden" name="return_to" value={@current_path} />
          <label for="locale-select">{gettext("Language")}</label>
          <select id="locale-select" name="locale" class="input w-auto" autocomplete="language">
            <option value="en" lang="en" selected={@locale == "en"}>English</option>
            <option value="fr" lang="fr" selected={@locale == "fr"}>Français</option>
          </select>
          <button type="submit" class="btn btn-secondary" id="locale-submit">{gettext("Apply")}</button>
        </.form>
      </div>
    </footer>
    """
  end

  @doc "Decorative brand sigil."
  def brand_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 32 32" class="size-8 shrink-0" aria-hidden="true">
      <circle cx="16" cy="16" r="15" class="fill-raised stroke-line" stroke-width="1" />
      <path d="M16 5l2.6 7.9H27l-6.8 4.9 2.6 8L16 21l-6.8 4.8 2.6-8L5 12.9h8.4z" class="fill-magic" />
      <circle cx="16" cy="16" r="2.2" class="fill-reward" />
    </svg>
    """
  end

  @doc "Flash toasts and the connection banner driven by `assets/js/connection.js`."
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"
  attr :member, :map, default: nil, doc: "signed-in member (offline copies of this device)"

  def flash_group(assigns) do
    ~H"""
    <div
      id="connection-status"
      class="connection-status"
      role="status"
      aria-live="polite"
      phx-update="ignore"
      data-reconnecting={gettext("Connection lost. Reconnecting…")}
      data-offline={
        gettext("You seem to be offline. Nothing can be saved until the connection is back.")
      }
      data-offline-lessons={
        gettext(
          "You seem to be offline. Live pages can't save anything until the connection is back, but your offline lessons still work."
        )
      }
      data-pending={gettext("Waiting for synchronization: %{count}", count: "%{count}")}
      hidden
    >
      <.icon name="hero-signal-slash" class="size-5 shrink-0" />
      <p class="min-w-0 flex-1 text-sm font-medium">
        <span id="connection-status-text"></span>
        <span id="connection-status-pending" class="block font-normal" hidden></span>
      </p>
      <a href={~p"/offline"} id="connection-offline-link" class="btn btn-secondary" hidden>
        <.icon name="hero-book-open" /> {gettext("Offline lessons")}
      </a>
      <button type="button" id="connection-retry" class="btn btn-secondary">
        <.icon name="hero-arrow-path" /> {gettext("Retry now")}
      </button>
    </div>
    <MysticWeb.OfflineComponents.offline_notice :if={@member} member={@member} />
    <div id={@id} class="toast-stack" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect…")}
      </.flash>
    </div>
    """
  end
end
