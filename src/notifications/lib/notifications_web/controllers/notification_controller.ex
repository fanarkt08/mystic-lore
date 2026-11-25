defmodule MlNotificationsWeb.NotificationController do
  @moduledoc "Notifications du membre du jeton (`conn.assigns.user_id`, jamais un identifiant de la requête)."
  use MlNotificationsWeb, :controller
  alias MlNotifications.{Accounts, Inbox, Notification}

  action_fallback MlNotificationsWeb.FallbackController

  def index(conn, params) do
    me = conn.assigns.user_id

    with {:ok, %{entries: entries, next_before: next}} <- Inbox.list(me, params) do
      actors = Accounts.identities(Enum.map(entries, & &1.actor_id))

      json(conn, %{
        entries: Enum.map(entries, &Notification.to_map(&1, actors)),
        next_before: next,
        unread: Inbox.unread_count(me)
      })
    end
  end

  def unread_count(conn, _params),
    do: json(conn, %{unread: Inbox.unread_count(conn.assigns.user_id)})

  def show(conn, %{"id" => id}) do
    with {:ok, n} <- Inbox.get(conn.assigns.user_id, id), do: render_one(conn, n)
  end

  def read(conn, %{"id" => id}) do
    with {:ok, n} <- Inbox.read(conn.assigns.user_id, id), do: render_one(conn, n)
  end

  def read_all(conn, _params) do
    count = Inbox.read_all(conn.assigns.user_id)
    json(conn, %{read: count, unread: Inbox.unread_count(conn.assigns.user_id)})
  end

  defp render_one(conn, n),
    do: json(conn, %{notification: Notification.to_map(n, Accounts.identities([n.actor_id]))})
end
