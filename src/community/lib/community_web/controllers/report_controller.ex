defmodule MlCommunityWeb.ReportController do
  use MlCommunityWeb, :controller
  alias MlCommunity.{Reports, Viewer}

  action_fallback MlCommunityWeb.FallbackController

  def create(conn, params) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, report} <- Reports.create(viewer, params) do
      conn |> put_status(:created) |> json(%{id: report.id})
    end
  end
end
