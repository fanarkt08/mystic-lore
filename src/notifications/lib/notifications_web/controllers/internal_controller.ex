defmodule MlNotificationsWeb.InternalController do
  @moduledoc """
  Routes des producteurs (jeton de service). Le service appelant (`svc` du jeton) ne crée que les catégories qui
  lui reviennent (`MlNotifications.Catalog`) : `403 forbidden` sinon.
  """
  use MlNotificationsWeb, :controller
  alias MlNotifications.Inbox

  action_fallback MlNotificationsWeb.FallbackController

  def create(conn, params) do
    with {:ok, result} <- Inbox.create(conn.assigns.caller, params) do
      conn
      |> put_status(if(result.status == "created", do: 201, else: 200))
      |> json(%{
        status: result.status,
        id: result.notification && result.notification.id,
        count: result.notification && result.notification.count,
        email: result.email
      })
    end
  end

  def read(conn, params) do
    with {:ok, count} <- Inbox.read_by_key(conn.assigns.caller, params),
         do: json(conn, %{read: count})
  end

  # Blocage chez social : plus rien entre les deux membres, dans les deux sens.
  def clear_between(%{assigns: %{caller: "social"}} = conn, params) do
    with {:ok, count} <- Inbox.clear_between(params), do: json(conn, %{deleted: count})
  end

  def clear_between(_conn, _params), do: {:error, :forbidden}
end
