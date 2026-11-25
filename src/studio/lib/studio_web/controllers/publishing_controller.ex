defmodule MlStudioWeb.PublishingController do
  use MlStudioWeb, :controller
  alias MlStudio.Publishing

  def checks(conn, %{"id" => id}) do
    with {:ok, result} <- Publishing.checks(conn.assigns.user_id, id), do: json(conn, result)
  end

  def attest(conn, %{"id" => id} = params) do
    with {:ok, project} <- Publishing.attest(conn.assigns.user_id, id, params),
         do: json(conn, %{attestations: View.attestations(project)})
  end

  def submit(conn, %{"id" => id}) do
    with {:ok, project} <- Publishing.submit(conn.assigns.user_id, id),
         do: json(conn, %{project: View.brief(project)})
  end

  def withdraw(conn, %{"id" => id}) do
    with {:ok, project} <- Publishing.withdraw(conn.assigns.user_id, id),
         do: json(conn, %{project: View.brief(project)})
  end
end
