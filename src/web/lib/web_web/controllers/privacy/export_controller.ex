defmodule MysticWeb.Privacy.ExportController do
  @moduledoc """
  Proxies a finished data export from accounts, which only serves an export to its owner.
  """
  use MysticWeb, :controller
  alias MysticWeb.{Api, Auth}

  def show(conn, %{"id" => id}) do
    path = "/api/me/exports/" <> URI.encode(id, &URI.char_unreserved?/1) <> "/download"

    with {:ok, user} <- Auth.resolve(get_session(conn, "session_token")),
         {:ok, %{"format" => _} = document} <- Api.get(user, :accounts, path) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="mysticlore-data-#{Date.utc_today()}.json")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Jason.encode_to_iodata!(document, pretty: true))
    else
      :anonymous ->
        conn
        |> put_flash(:error, gettext("Please log in to continue."))
        |> redirect(to: Auth.login_path(~p"/settings/data"))

      # explained by the data settings (`MysticWeb.AccessComponents`), with the next step
      {:error, {:http, status, _}} when status in [404, 409, 410] ->
        reason = %{404 => "missing", 409 => "not_ready", 410 => "expired"}[status]
        redirect(conn, to: ~p"/settings/data?#{[export: reason]}")

      error ->
        conn |> put_flash(:error, Api.error_message(error)) |> redirect(to: ~p"/settings/data")
    end
  end
end
