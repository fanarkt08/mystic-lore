defmodule MlAccountsWeb.PrivacyController do
  @moduledoc "Données personnelles du membre connecté : exports et suppression du compte (`MlAccounts.Privacy`)."
  use MlAccountsWeb, :controller
  alias MlAccounts.Privacy

  def create_export(conn, params) do
    with {:ok, export} <- Privacy.request_export(conn.assigns.current_user, params["password"]) do
      conn |> put_status(202) |> json(%{id: export.id, status: export.status})
    end
  end

  def exports(conn, _params) do
    exports = Privacy.list_exports(conn.assigns.current_user)
    json(conn, %{exports: Enum.map(exports, &export/1)})
  end

  def download(conn, %{"id" => id}) do
    with {:ok, document} <- Privacy.download(conn.assigns.current_user, id),
         do: json(conn, document)
  end

  def schedule_deletion(conn, params) do
    with {:ok, user} <- Privacy.schedule_deletion(conn.assigns.current_user, params),
         do: json(conn, %{deletion_scheduled_at: user.deletion_scheduled_at})
  end

  def cancel_deletion(conn, _params) do
    with {:ok, _user} <- Privacy.cancel_deletion(conn.assigns.current_user),
         do: send_resp(conn, 204, "")
  end

  defp export(e) do
    %{
      id: e.id,
      status: Privacy.status(e),
      failed_services: e.failed_services,
      inserted_at: e.inserted_at,
      completed_at: e.completed_at,
      expires_at: e.expires_at
    }
  end
end
