defmodule MlCommunityWeb.ModerationController do
  @moduledoc """
  Outils du staff, dont le rôle est vérifié auprès d'accounts à chaque requête.
  """
  use MlCommunityWeb, :controller
  alias MlCommunity.{Accounts, Moderation, Reports, Viewer}
  alias MlCommunityWeb.{FallbackController, Json}

  action_fallback FallbackController
  plug :require_staff

  def discussion(conn, %{"id" => id} = params), do: act(conn, :discussion, id, params)
  def reply(conn, %{"id" => id} = params), do: act(conn, :reply, id, params)

  defp act(conn, type, id, params) do
    with :ok <- Moderation.act(conn.assigns.user_id, type, id, params),
         do: send_resp(conn, 204, "")
  end

  def reports(conn, params) do
    page = Reports.list_open(params["page"])
    users = Accounts.users(Enum.flat_map(page.entries, &people/1))
    json(conn, %{page | entries: Enum.map(page.entries, &Json.report(&1, users))})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, report} <- Reports.get(id),
         do: json(conn, %{report: Json.report(report, Accounts.users(people(report)))})
  end

  def stats(conn, _params), do: json(conn, %{stats: Reports.stats()})

  def resolve(conn, %{"id" => id} = params) do
    with {:ok, report} <- Reports.resolve(conn.assigns.user_id, id, params) do
      json(conn, %{report: Json.report(report, Accounts.users(people(report)))})
    end
  end

  defp people(report), do: [report.reporter_id, report.snapshot["author_id"]]

  defp require_staff(conn, _opts) do
    case Viewer.require_staff(conn.assigns.user_id) do
      :ok -> conn
      error -> conn |> FallbackController.call(error) |> halt()
    end
  end
end
