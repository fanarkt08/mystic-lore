defmodule MlLearningWeb.ImportController do
  @moduledoc "Import d'une aventure, réservé au service studio."
  use MlLearningWeb, :controller

  def create(%{assigns: %{caller: "studio"}} = conn, params) do
    case MlLearning.Importer.import(params) do
      {:ok, result} ->
        json(conn, result)

      {:error, :stale_version} ->
        conn |> put_status(409) |> json(%{error: "stale_version"})

      {:error, {:invalid, errors}} ->
        conn |> put_status(422) |> json(%{error: "invalid", errors: errors})
    end
  end

  def create(conn, _params), do: conn |> put_status(403) |> json(%{error: "forbidden"})
end
