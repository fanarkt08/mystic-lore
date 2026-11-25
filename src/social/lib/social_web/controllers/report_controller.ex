defmodule MlSocialWeb.ReportController do
  use MlSocialWeb, :controller

  action_fallback MlSocialWeb.FallbackController

  def create(conn, params) do
    with {:ok, report} <- MlSocial.Reports.create(conn.assigns.user_id, params) do
      conn |> put_status(:created) |> json(%{id: report.id})
    end
  end
end
