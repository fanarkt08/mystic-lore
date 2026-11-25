defmodule MlMultiplayerWeb.LinkController do
  @moduledoc "Liens d'invitation. Le jeton circule dans le corps (`token`, filtré des journaux), jamais dans l'URL."
  use MlMultiplayerWeb, :controller
  alias MlMultiplayer.{Accounts, Invitations, Lobbies}
  alias MlMultiplayerWeb.LobbyJSON

  action_fallback MlMultiplayerWeb.FallbackController

  def create(conn, %{"id" => id} = params) do
    with {:ok, link, token} <- Invitations.create_link(conn.assigns.user_id, id, params) do
      conn |> put_status(:created) |> json(%{link: Map.put(LobbyJSON.link(link), :token, token)})
    end
  end

  def revoke(conn, %{"id" => id, "link_id" => link_id}) do
    with :ok <- Invitations.revoke_link(conn.assigns.user_id, id, link_id),
         do: send_resp(conn, 204, "")
  end

  def preview(conn, params) do
    with {:ok, lobby} <- Invitations.preview(params["token"]) do
      users = Accounts.users([lobby.host_id])
      count = Map.get(Lobbies.counts([lobby.id]), lobby.id, 0)
      json(conn, %{lobby: LobbyJSON.summary(%{lobby: lobby, member_count: count}, users)})
    end
  end

  def join(conn, params) do
    with {:ok, lobby_id} <- Invitations.join_link(conn.assigns.user_id, params["token"]),
         do: json(conn, %{lobby_id: lobby_id})
  end
end
