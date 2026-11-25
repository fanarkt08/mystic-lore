defmodule MlNotificationsWeb.SettingsController do
  use MlNotificationsWeb, :controller
  alias MlNotifications.Preferences

  action_fallback MlNotificationsWeb.FallbackController

  def show(conn, _params),
    do: json(conn, %{settings: Preferences.to_map(Preferences.get(conn.assigns.user_id))})

  def update(conn, params) do
    with {:ok, setting} <-
           Preferences.update(conn.assigns.user_id, Map.take(params, ~w(channels quiet_hours))) do
      json(conn, %{settings: Preferences.to_map(setting)})
    end
  end
end
