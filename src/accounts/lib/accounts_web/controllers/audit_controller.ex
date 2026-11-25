defmodule MlAccountsWeb.AuditController do
  @moduledoc "Écriture du journal d'audit par les autres services, et lecture ou export par les admins."
  use MlAccountsWeb, :controller
  alias MlAccounts.Audit
  alias MlAccountsWeb.AdminJSON

  def create(conn, params) do
    if conn.assigns.caller in Audit.writers() do
      with {:ok, entry} <- Audit.create(conn.assigns.caller, params),
           do: conn |> put_status(201) |> json(%{id: entry.id})
    else
      {:error, :forbidden}
    end
  end

  def index(conn, params) do
    with {:ok, page} <- Audit.list(params),
         do: json(conn, %{page | entries: Enum.map(page.entries, &AdminJSON.audit_entry/1)})
  end

  def export(conn, params) do
    with {:ok, csv, truncated} <- Audit.export(conn.assigns.current_user, params) do
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-export-truncated", to_string(truncated))
      |> send_resp(200, csv)
    end
  end
end
