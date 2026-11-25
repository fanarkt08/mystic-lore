defmodule MlCommunityWeb.PrivacyController do
  @moduledoc "Routes internes de données personnelles, réservées au service accounts."
  use MlCommunityWeb, :controller

  plug :accounts_only

  def export(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, user_id} -> json(conn, %{data: MlCommunity.Privacy.export(user_id)})
      :error -> not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, user_id} <- Ecto.UUID.cast(id) do
      :ok = MlCommunity.Privacy.delete(user_id)
      send_resp(conn, 204, "")
    else
      :error -> not_found(conn)
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp accounts_only(%{assigns: %{caller: "accounts"}} = conn, _opts), do: conn

  defp accounts_only(conn, _opts),
    do: conn |> put_status(403) |> json(%{error: "forbidden"}) |> halt()
end
