defmodule MlCommunityWeb.HealthController do
  use MlCommunityWeb, :controller

  def show(conn, _params) do
    case MlCommunity.Repo.query("SELECT 1") do
      {:ok, _} -> json(conn, %{status: "ok"})
      {:error, _} -> conn |> put_status(503) |> json(%{status: "unavailable"})
    end
  end
end
