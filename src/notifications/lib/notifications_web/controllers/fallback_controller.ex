defmodule MlNotificationsWeb.FallbackController do
  @moduledoc "Traduit les erreurs des contextes au format du contrat : `{\"error\": code}` (+ `errors` en 422)."
  use MlNotificationsWeb, :controller

  def call(conn, {:error, {:invalid, errors}}),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  def call(conn, {:error, :forbidden}),
    do: conn |> put_status(403) |> json(%{error: "forbidden"})

  def call(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})
end
