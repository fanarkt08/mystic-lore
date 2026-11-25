defmodule MlStudioWeb.ModerationController do
  @moduledoc "Review queue of the staff (role read from accounts on every call)."
  use MlStudioWeb, :controller
  alias MlStudio.Publishing

  def queue(conn, _params) do
    with {:ok, projects} <- Publishing.queue(conn.assigns.user_id),
         do: json(conn, %{projects: Enum.map(projects, &View.brief/1)})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, review} <- Publishing.review(conn.assigns.user_id, id) do
      json(conn, %{
        project: View.brief(review.project),
        version: Map.put(View.version(review.version), "snapshot", review.version.snapshot),
        checks: review.checks,
        attestations: review.attestations
      })
    end
  end

  def approve(conn, %{"id" => id}) do
    with {:ok, project} <- Publishing.approve(conn.assigns.user_id, id),
         do: json(conn, %{project: View.brief(project)})
  end

  def reject(conn, %{"id" => id} = params) do
    with {:ok, project} <- Publishing.reject(conn.assigns.user_id, id, params),
         do: json(conn, %{project: View.brief(project)})
  end

  def stats(conn, _params) do
    with {:ok, stats} <- Publishing.stats(conn.assigns.user_id), do: json(conn, %{stats: stats})
  end

  def retry_import(conn, %{"id" => id}) do
    with {:ok, _project} <- Publishing.retry_import(conn.assigns.user_id, id),
         do: conn |> put_status(202) |> json(%{status: "queued"})
  end
end
