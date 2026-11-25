defmodule MlStudioWeb.CollaboratorController do
  use MlStudioWeb, :controller
  alias MlStudio.Projects

  def create(conn, %{"id" => id} = params) do
    with {:ok, collaborator} <- Projects.invite(conn.assigns.user_id, id, params),
         do: conn |> put_status(201) |> json(%{collaborator: View.collaborator(collaborator)})
  end

  def update(conn, %{"id" => id, "user_id" => member_id} = params) do
    with {:ok, collaborator} <-
           Projects.update_collaborator(conn.assigns.user_id, id, member_id, params),
         do: json(conn, %{collaborator: View.collaborator(collaborator)})
  end

  def delete(conn, %{"id" => id, "user_id" => member_id}) do
    with {:ok, _} <- Projects.remove_collaborator(conn.assigns.user_id, id, member_id),
         do: send_resp(conn, 204, "")
  end
end
