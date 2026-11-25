defmodule MysticWeb.Legal do
  @moduledoc """
  Content of the provisional legal pages, written from what the code actually does.
  Bump the version of a document whenever its text changes.
  """
  use Gettext, backend: MysticWeb.Gettext

  @documents ~w(privacy terms cookies accessibility)
  # 0.2 : leçons hors ligne (service worker, Cache Storage et IndexedDB dans les cookies, copie sur l'appareil
  # dans la vie privée) et accessibilité (audit axe-core, vérifications scriptées, ce qui n'est pas fait)
  @versions %{
    "privacy" => {"0.2", "2026-11-24"},
    "terms" => {"0.1", "2026-11-24"},
    "cookies" => {"0.2", "2026-11-24"},
    "accessibility" => {"0.2", "2026-11-24"}
  }

  def documents, do: @documents
  def document?(doc), do: doc in @documents

  @doc "`{version, ISO date of the last update}`."
  def version(doc), do: Map.fetch!(@versions, doc)

  def title("privacy"), do: gettext("Privacy notice")
  def title("terms"), do: gettext("Terms of use")
  def title("cookies"), do: gettext("Cookies and browser storage")
  def title("accessibility"), do: gettext("Accessibility statement")

  def summary("privacy"),
    do:
      gettext(
        "What each part of MysticLore keeps about you, for how long, who else may receive it, and your rights."
      )

  def summary("terms"),
    do: gettext("The rules of the academy: accounts, conduct, content, memberships and payments.")

  def summary("cookies"),
    do:
      gettext(
        "Every cookie and every item of browser storage, why it exists, and why there is no consent banner."
      )

  def summary("accessibility"),
    do:
      gettext(
        "What we aim for, what was checked automatically, what wasn't, and the known limitations."
      )

  def icon("privacy"), do: "hero-lock-closed"
  def icon("terms"), do: "hero-document-text"
  def icon("cookies"), do: "hero-circle-stack"
  def icon("accessibility"), do: "hero-eye"

  @doc """
  Cookies set on this site, as found in the code: `MysticWeb.Endpoint` (session), `MysticWeb.LocaleController`
  (visitor language) and the LiveView client (`__phoenix_flash__`, `__phoenix_reload_status__`).
  """
  def cookies do
    [
      %{
        name: "_mystic_web",
        by: gettext("This server"),
        purpose:
          gettext(
            "Your session: the opaque session token of your account (never your password), the protection against forged forms (CSRF), the language of the page, the page to go back to after logging in, the pending step of a two-factor login and the messages shown after a redirect. Signed and encrypted; JavaScript can't read it (HttpOnly); SameSite=Lax; sent over HTTPS only in production."
          ),
        duration: gettext("30 days at most; ends when you log out"),
        kind: gettext("Strictly necessary")
      },
      %{
        name: "ml_locale",
        by: gettext("This server"),
        purpose:
          gettext(
            "The language you chose with the selector at the bottom of the page, as a visitor. Only set when you choose one. HttpOnly, SameSite=Lax."
          ),
        duration: gettext("1 year"),
        kind: gettext("Set at your request")
      },
      %{
        name: "__phoenix_flash__",
        by: gettext("This site's own script (Phoenix LiveView)"),
        purpose:
          gettext(
            "Carries a short message (for example « Please log in to continue ») to the next page when a live page sends you elsewhere."
          ),
        duration: gettext("60 seconds"),
        kind: gettext("Strictly necessary")
      },
      %{
        name: "__phoenix_reload_status__",
        by: gettext("This site's own script (Phoenix LiveView)"),
        purpose:
          gettext(
            "Set only when the server asks an open page to reload itself (for example after an update), so that the reload is not repeated in a loop."
          ),
        duration: gettext("60 seconds"),
        kind: gettext("Strictly necessary")
      }
    ]
  end

  @doc "Browser storage found in the code: the LiveView client's and, when used, the offline lessons'."
  def storage do
    framework_storage() ++ offline_storage()
  end

  defp offline_storage do
    [
      %{
        who: :offline,
        name: "/sw.js",
        where: gettext("Service worker"),
        purpose:
          gettext(
            "Registered on a device only once a member chooses « Make available offline » there (a visitor's pages never register it). It keeps this site's own files (styles, scripts, fonts, icons, images) and the offline page, so that downloaded lessons open without a connection, and it shows the offline page when a page can't be reached. It never keeps the pages of your account, the answers of the services, the live connection or anything you send."
          ),
        duration:
          gettext(
            "Until you log out (the server then asks the browser to remove it, with this site's storage), « Clear offline data » in your settings, or the deletion of this site's data."
          )
      },
      %{
        who: :offline,
        name: "mysticlore-static-<version>",
        where: "Cache Storage",
        purpose:
          gettext(
            "The site's files and the offline page (no lesson, no answer, nothing about your account except the language, time zone and display preferences of that page). Replaced at each update of the site."
          ),
        duration:
          gettext(
            "Until the next update of the site, your logout, « Clear offline data » or the deletion of this site's data."
          )
      },
      %{
        who: :offline,
        name: "mysticlore-offline",
        where: "IndexedDB",
        purpose:
          gettext(
            "Only if you choose « Make available offline »: the copies of premium lessons (their text and questions, never the answers), your member identifier, the version and the download and expiry dates of each copy, the answers and finished stories waiting for synchronization, and the results of the last synchronization."
          ),
        duration:
          gettext(
            "Each copy expires after %{days} days at most and never after the end of your paid period; an expired copy is deleted. When your Premium access ends, the copies are deleted (answers still waiting stay, and are refused with the reason if the access is still over when they are synchronized). Everything is deleted when you log out, when another member logs in on this device and with « Clear offline data » in your settings.",
            days: MysticWeb.Offline.max_days()
          )
      }
    ]
  end

  defp framework_storage do
    [
      %{
        who: :framework,
        name: gettext("<page path>-consecutive-reloads"),
        where: "localStorage",
        duration: gettext("Removed as soon as the page connects"),
        purpose:
          gettext(
            "Phoenix LiveView counts the reloads of a page that fails to connect, to slow them down; the entry is removed as soon as the page connects."
          )
      },
      %{
        who: :framework,
        name: "phx:nav-history-position",
        where: "sessionStorage",
        duration: gettext("Until the tab is closed"),
        purpose:
          gettext(
            "Phoenix LiveView remembers your position in this tab's history, so that Back and Forward restore the right page and scroll position."
          )
      },
      %{
        who: :framework,
        name: "phx:fallback:LongPoll",
        where: "sessionStorage",
        duration: gettext("Until the tab is closed"),
        purpose:
          gettext(
            "Phoenix remembers, for this tab only, that live connections (WebSocket) don't work on your network, to use the slower but compatible mode directly."
          )
      },
      %{
        who: :framework,
        name: "phx:live-socket:debug",
        where: "sessionStorage",
        duration: gettext("Until the tab is closed"),
        purpose:
          gettext(
            "Phoenix LiveView turns its debugging messages on by itself when the site is opened at « localhost » (development only). Two similar entries (profiling, latency simulation) exist only if a developer turns them on from the browser console."
          )
      }
    ]
  end
end
