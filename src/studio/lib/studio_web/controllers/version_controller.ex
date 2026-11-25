defmodule MlStudioWeb.VersionController do
  use MlStudioWeb, :controller
  alias MlStudio.Projects

  def index(conn, %{"id" => id}) do
    with {:ok, versions} <- Projects.versions(conn.assigns.user_id, id),
         do: json(conn, %{versions: Enum.map(versions, &View.version/1)})
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, version} <- Projects.create_version(conn.assigns.user_id, id, params),
         do: conn |> put_status(201) |> json(%{version: View.version(version)})
  end

  def restore(conn, %{"id" => id, "version_id" => version_id}) do
    with {:ok, version} <- Projects.restore_version(conn.assigns.user_id, id, version_id),
         {:ok, project, role} <- Projects.get(conn.assigns.user_id, id) do
      conn
      |> put_status(201)
      |> json(%{version: View.version(version), project: View.project(project, role)})
    end
  end
end
