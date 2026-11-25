defmodule MlAccountsWeb.IncidentController do
  @moduledoc "Incidents du staff : liste, ouverture, détail avec chronologie, mises à jour (résolution avec résumé)."
  use MlAccountsWeb, :controller
  alias MlAccounts.{Incidents, Staff}
  alias MlAccountsWeb.AdminJSON

  def index(conn, params) do
    page = Incidents.list(params)
    people = Staff.people(Enum.flat_map(page.entries, &[&1.created_by, &1.resolved_by]))
    json(conn, %{page | entries: Enum.map(page.entries, &AdminJSON.incident(&1, people))})
  end

  def create(conn, params) do
    with {:ok, incident} <- Incidents.open(conn.assigns.current_user, params),
         do: conn |> put_status(201) |> render_detail(incident)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, incident} <- Incidents.get(id), do: render_detail(conn, incident)
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, incident} <- Incidents.add_update(conn.assigns.current_user, id, params),
         do: render_detail(conn, incident)
  end

  defp render_detail(conn, incident) do
    ids = [incident.created_by, incident.resolved_by | Enum.map(incident.updates, & &1.author_id)]
    json(conn, %{incident: AdminJSON.incident_detail(incident, Staff.people(ids))})
  end
end
