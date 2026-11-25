defmodule MlStudioWeb.HealthController do
  use MlStudioWeb, :controller

  def show(conn, _params) do
    if db_up?(),
      do: json(conn, %{status: "ok"}),
      else: conn |> put_status(503) |> json(%{status: "unavailable"})
  end

  defp db_up? do
    match?({:ok, _}, MlStudio.Repo.query("SELECT 1"))
  rescue
    _ -> false
  end
end
