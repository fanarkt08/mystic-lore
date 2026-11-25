defmodule MlMultiplayerWeb.HealthController do
  use MlMultiplayerWeb, :controller

  def show(conn, _params) do
    case MlMultiplayer.Repo.query("SELECT 1") do
      {:ok, _} -> json(conn, %{status: "ok"})
      {:error, _} -> conn |> put_status(503) |> json(%{status: "unavailable"})
    end
  end
end
