defmodule MysticWeb.Auth do
  @moduledoc """
  Browser authentication. The session cookie only holds the opaque accounts token, kept out of the assigns so
  that a template can never render it.
  """
  use MysticWeb, :verified_routes
  use Gettext, backend: MysticWeb.Gettext
  import Plug.Conn
  alias Phoenix.{Component, LiveView}
  alias MysticWeb.Api

  @doc "`{:ok, user}`, `:anonymous` (no/invalid token) or `{:error, :unavailable}`."
  def resolve(nil), do: :anonymous

  def resolve(token) when is_binary(token) do
    case Api.current_session(token) do
      {:ok, %{"user" => %{"id" => _} = user}} -> {:ok, user}
      {:error, {:http, 401, _}} -> :anonymous
      _ -> {:error, :unavailable}
    end
  end

  ## Controllers

  @doc """
  Plug for guest-only pages (login, register): already signed-in users go to their dashboard (or to the local page
  of `return_to`, checked by `return_path/1`).
  """
  def redirect_if_user(conn, _opts) do
    case resolve(get_session(conn, "session_token")) do
      {:ok, _user} ->
        to = return_path(conn.params["return_to"]) || ~p"/dashboard"
        conn |> Phoenix.Controller.redirect(to: to) |> halt()

      _ ->
        conn
    end
  end

  @doc """
  Where a member goes once logged in: the page they were sent away from (`return_to`), else the welcome tour for a
  confirmed account that hasn't finished or skipped it (accounts `onboarding.status`), else the dashboard.
  """
  def after_login_path(user, return_to) do
    cond do
      path = return_path(return_to) -> path
      onboarding_pending?(user) -> ~p"/welcome"
      true -> ~p"/dashboard"
    end
  end

  def onboarding_pending?(%{"confirmed" => true, "onboarding" => %{"status" => "pending"}}),
    do: true

  def onboarding_pending?(_user), do: false

  @doc "Starts a fresh session (prevents fixation) holding the accounts session token."
  def log_in(conn, token) do
    locale = get_session(conn, "locale")

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session("session_token", token)
    |> put_session("live_socket_id", live_socket_id(token))
    |> put_session("locale", locale)
  end

  @doc "Revokes the token at accounts (best effort), disconnects its LiveViews and clears the session."
  def log_out(conn) do
    if token = get_session(conn, "session_token"), do: Api.revoke_session(token)

    if socket_id = get_session(conn, "live_socket_id"),
      do: MysticWeb.Endpoint.broadcast(socket_id, "disconnect", %{})

    conn |> configure_session(renew: true) |> clear_session()
  end

  defp live_socket_id(token),
    do: "sessions:" <> Base.url_encode64(:crypto.hash(:sha256, token), padding: false)

  ## LiveViews

  def on_mount(:mount_current_user, _params, session, socket) do
    case resolve(session["session_token"]) do
      {:ok, user} ->
        {:cont, track_user(socket, user, session["session_token"])}

      _ ->
        {:cont, Component.assign(socket, current_user: nil, unread: nil, notifications: nil)}
    end
  end

  def on_mount(:require_user, _params, session, socket) do
    token = session["session_token"]

    case resolve(token) do
      {:ok, user} ->
        {:cont, track_user(socket, user, token)}

      # accounts refused the session: the login page explains it and brings the member back afterwards
      :anonymous when is_binary(token) ->
        {:halt, LiveView.redirect(socket, to: login_path(page_path(socket), "expired"))}

      :anonymous ->
        {:halt, to_login(socket, gettext("Please log in to continue."), page_path(socket))}

      {:error, :unavailable} ->
        message =
          gettext("We can't verify your session right now. Please try again in a moment.")

        {:halt, to_login(socket, message, page_path(socket))}
    end
  end

  defp to_login(socket, message, return_to),
    do:
      socket
      |> LiveView.put_flash(:error, message)
      |> LiveView.redirect(to: login_path(return_to))

  # The page that was asked for. Known at the first (HTTP) render only: a connected mount doesn't carry its URL.
  defp page_path(socket) do
    case LiveView.get_connect_info(socket, :uri) do
      %URI{path: "/" <> _ = path, query: query} when query in [nil, ""] -> path
      %URI{path: "/" <> _ = path, query: query} -> path <> "?" <> query
      _ -> nil
    end
  end

  @doc """
  The login page, with the local page to come back to afterwards (`return_to`, checked by `return_path/1`) and the
  reason of the visit (`"expired"`: the session ended, explained on the page).
  """
  def login_path(return_to \\ nil, reason \\ nil) do
    query =
      Enum.reject([reason: reason, return_to: return_path(return_to)], fn {_k, v} -> is_nil(v) end)

    if query == [], do: ~p"/login", else: ~p"/login?#{query}"
  end

  @guest_pages ~w(login logout register confirm forgot-password reset-password)

  @doc """
  A page of this site worth coming back to after logging in, or nil: never another site (same rules as the
  language selector, `MysticWeb.Locale.local_path/1`), the home page or a guest page (login, sign-up…).
  """
  def return_path(path) when is_binary(path) do
    case MysticWeb.Locale.local_path(path) do
      "/" ->
        nil

      "/" <> rest = local ->
        first = rest |> String.split(["/", "?"], parts: 2) |> hd()
        if first in @guest_pages, do: nil, else: local
    end
  end

  def return_path(_path), do: nil

  @doc "The accounts session token of a signed-in LiveView."
  def session_token(socket), do: socket.private[:session_token]

  @doc "Headers naming the current session to accounts (`current` flag, sessions kept on revocation)."
  def session_headers(socket), do: [{"x-session-token", session_token(socket)}]

  defp track_user(socket, user, token) do
    socket =
      socket
      |> Component.assign(
        current_user: user,
        unread: nil,
        notifications: %{unread: nil, toast: nil}
      )
      |> LiveView.put_private(:session_token, token)

    if LiveView.connected?(socket) do
      MlShared.Events.subscribe(MlShared.Events.user(user["id"]))
      MysticWeb.Presence.track_member(self(), user["id"])

      socket
      |> load_unread()
      |> load_notifications()
      |> LiveView.attach_hook(:user_events, :handle_info, &user_event/2)
      |> LiveView.attach_hook(:notification_toast, :handle_event, &toast_event/3)
    else
      socket
    end
  end

  ## Notifications: bell count and toast

  @toast_ms 8_000

  defp load_notifications(socket),
    do: put_notifications(socket, :unread, MysticWeb.Notifications.unread_count(socket))

  defp put_notifications(socket, key, value),
    do: Component.update(socket, :notifications, &Map.put(&1 || %{}, key, value))

  # a new notification to announce (not in quiet hours: the center sends `nil` then), unless the page shows it
  # live itself: `@toast_except` is `:all`, or a list of categories or `{category, subject type, subject id}`
  defp show_toast(socket, %{"id" => id, "category" => category}) when is_binary(id) do
    except = socket.assigns[:toast_except] || []

    with true <- except != :all and category not in except,
         %{"read" => false} = notification <- MysticWeb.Notifications.fetch(socket, id),
         false <-
           {category, notification["subject"]["type"], notification["subject"]["id"]} in except do
      Process.send_after(self(), {:notification_toast_expired, id}, @toast_ms)
      put_notifications(socket, :toast, notification)
    else
      _ -> socket
    end
  end

  defp show_toast(socket, _toast), do: socket

  defp toast_event("dismiss-notification-toast", _params, socket),
    do: {:halt, put_notifications(socket, :toast, nil)}

  defp toast_event(_event, _params, socket), do: {:cont, socket}

  defp load_unread(socket) do
    case Api.get(socket, :social, "/api/me/unread") do
      {:ok, %{"messages" => _} = counts} -> Component.assign(socket, :unread, counts)
      _ -> socket
    end
  end

  defp user_event({tag, _user_id}, socket) when tag in [:unread_changed, :friendship_changed],
    do: continue(load_unread(socket))

  # the notification center changed this member's list: bell count, maybe a toast (the view may reload too)
  defp user_event({:notifications_changed, _user_id, toast}, socket),
    do: socket |> load_notifications() |> show_toast(toast) |> continue()

  defp user_event({:notification_toast_expired, id}, socket) do
    socket =
      case socket.assigns[:notifications] do
        %{toast: %{"id" => ^id}} -> put_notifications(socket, :toast, nil)
        _ -> socket
      end

    {:halt, socket}
  end

  # Accounts unreachable: keep the page; only a refused token signs the member out.
  defp user_event({:sessions_revoked, _user_id}, socket) do
    case resolve(session_token(socket)) do
      {:ok, user} ->
        continue(Component.assign(socket, :current_user, user))

      :anonymous ->
        {:halt,
         LiveView.redirect(socket, to: login_path(socket.assigns[:current_path], "expired"))}

      {:error, :unavailable} ->
        continue(socket)
    end
  end

  # Role or sanction changed by the staff: reload the member (navigation, staff pages, restriction notices).
  defp user_event({tag, _user_id}, socket) when tag in [:role_changed, :sanction_changed] do
    case resolve(session_token(socket)) do
      {:ok, user} -> continue(Component.assign(socket, :current_user, user))
      _ -> continue(socket)
    end
  end

  # Profile, preferences or avatar changed (another tab, a moderator's reset): reload the member, re-apply.
  defp user_event({:profile_changed, _user_id}, socket) do
    case Api.get(socket, :accounts, "/api/me") do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        socket
        |> Component.assign(:current_user, user)
        |> MysticWeb.Preferences.refresh()
        |> continue()

      _ ->
        continue(socket)
    end
  end

  # A VIP theme follows the effective plan; when no paid plan is left, the offline premium lessons are deleted.
  defp user_event({:entitlements_changed, _user_id, plan}, socket) do
    paused_before? = socket.assigns[:theme_paused] == true
    socket = socket |> MysticWeb.Preferences.refresh(plan) |> purge_offline(plan)

    socket =
      if socket.assigns[:theme_paused] == true and not paused_before?,
        do:
          LiveView.put_flash(
            socket,
            :info,
            gettext(
              "Your VIP access has ended: your VIP theme is paused. Renew VIP from the Membership page to bring it back."
            )
          ),
        else: socket

    continue(socket)
  end

  defp user_event(_msg, socket), do: continue(socket)

  defp purge_offline(socket, plan) when plan in ~w(premium vip), do: socket

  defp purge_offline(socket, _plan) do
    message =
      case MysticWeb.Offline.paid_access(socket.assigns.current_user) do
        # billing already reports a paid plan again (a newer change): nothing to delete
        {:ok, true} -> nil
        {:ok, false, message} -> message
        :unknown -> MysticWeb.Offline.ended_message(nil)
      end

    if message,
      do: LiveView.push_event(socket, "ml:offline-purge", %{message: message}),
      else: socket
  end

  defp continue(socket) do
    if function_exported?(socket.view, :handle_info, 2),
      do: {:cont, socket},
      else: {:halt, socket}
  end
end
