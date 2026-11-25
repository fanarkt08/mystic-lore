defmodule MysticWeb.Admin.AuditExportController do
  @moduledoc "CSV export of the audit log, proxied from accounts for admins only."
  use MysticWeb, :controller
  alias MysticWeb.{Api, Auth}
  alias MysticWeb.Admin.Guard

  @filters ~w(action actor from to)

  def show(conn, params) do
    with {:ok, user} <- Auth.resolve(get_session(conn, "session_token")),
         true <- Guard.admin?(user) || {:error, :forbidden},
         {:ok, csv} when is_binary(csv) <-
           Api.get(user, :accounts, "/api/admin/audit/export",
             params: params |> Map.take(@filters) |> Map.to_list()
           ) do
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="mysticlore-audit-#{Date.utc_today()}.csv")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, csv)
    else
      :anonymous ->
        conn
        |> put_flash(:error, gettext("Please log in to continue."))
        |> redirect(to: ~p"/login")

      {:error, :forbidden} ->
        raise MysticWeb.ForbiddenError

      {:error, {:http, 403, _}} ->
        raise MysticWeb.ForbiddenError

      error ->
        conn |> put_flash(:error, Api.error_message(error)) |> redirect(to: ~p"/admin/audit")
    end
  end
end
