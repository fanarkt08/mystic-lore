defmodule MlStudioWeb.ProjectController do
  use MlStudioWeb, :controller
  alias MlStudio.Projects

  def index(conn, _params) do
    %{owned: owned, shared: shared} = Projects.list(conn.assigns.user_id)
    summary = fn {project, role, counts} -> View.summary(project, role, counts) end
    json(conn, %{owned: Enum.map(owned, summary), shared: Enum.map(shared, summary)})
  end

  def create(conn, params) do
    with {:ok, project} <- Projects.create(conn.assigns.user_id, params),
         {:ok, project, role} <- Projects.get(conn.assigns.user_id, project.id) do
      conn |> put_status(201) |> json(%{project: View.project(project, role)})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, project, role} <- Projects.get(conn.assigns.user_id, id),
         do: json(conn, %{project: View.project(project, role)})
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, project} <- Projects.update_brief(conn.assigns.user_id, id, params),
         do: json(conn, %{project: View.brief(project)})
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _project} <- Projects.delete(conn.assigns.user_id, id),
         do: send_resp(conn, 204, "")
  end
end
