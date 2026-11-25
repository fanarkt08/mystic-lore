defmodule MlLearningWeb.HealthController do
  use MlLearningWeb, :controller

  def show(conn, _params) do
    if database_up?(),
      do: json(conn, %{status: "ok"}),
      else: conn |> put_status(503) |> json(%{status: "unavailable"})
  end

  defp database_up? do
    match?({:ok, _}, MlLearning.Repo.query("SELECT 1"))
  rescue
    DBConnection.ConnectionError -> false
  end
end
