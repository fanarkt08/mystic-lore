defmodule MlBillingWeb.AdminController do
  @moduledoc "Routes admin de billing (rôle admin vérifié chez accounts à chaque requête) : lecture et ajustement de crédits."
  use MlBillingWeb, :controller
  alias MlBilling.Admin

  action_fallback MlBillingWeb.FallbackController
  plug :require_admin

  def stats(conn, _params), do: json(conn, %{stats: Admin.stats()})
  def subscriptions(conn, params), do: json(conn, Admin.subscriptions(params))
  def webhook_events(conn, params), do: json(conn, Admin.failed_events(params))

  def adjust_credits(conn, params) do
    with {:ok, result} <- Admin.adjust_credits(conn.assigns.user_id, params) do
      conn
      |> put_status(if(result.status == "applied", do: 201, else: 200))
      |> json(%{adjustment: result})
    end
  end

  defp require_admin(conn, _opts) do
    case Admin.require_admin(conn.assigns.user_id) do
      :ok -> conn
      error -> conn |> MlBillingWeb.FallbackController.call(error) |> halt()
    end
  end
end
