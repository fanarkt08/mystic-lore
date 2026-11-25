defmodule MlMultiplayerWeb.InviteController do
  use MlMultiplayerWeb, :controller
  alias MlMultiplayer.{Accounts, Invitations}
  alias MlMultiplayerWeb.LobbyJSON

  action_fallback MlMultiplayerWeb.FallbackController

  def index(conn, _params) do
    with {:ok, entries} <- Invitations.list_for(conn.assigns.user_id) do
      users =
        Accounts.users(Enum.flat_map(entries, &[&1.invite.inviter_id, &1.lobby.host_id]))

      json(conn, %{
        invites:
          for entry <- entries do
            %{
              id: entry.invite.id,
              inviter: users[entry.invite.inviter_id],
              lobby: LobbyJSON.summary(entry, users),
              inserted_at: entry.invite.inserted_at
            }
          end
      })
    end
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, invite} <- Invitations.invite(conn.assigns.user_id, id, params["user_id"]) do
      users = Accounts.users([invite.invitee_id])

      conn
      |> put_status(:created)
      |> json(%{
        invite: %{
          id: invite.id,
          lobby_id: invite.lobby_id,
          invitee: users[invite.invitee_id],
          status: invite.status
        }
      })
    end
  end

  def accept(conn, %{"id" => id}) do
    with {:ok, lobby_id} <- Invitations.accept(conn.assigns.user_id, id),
         do: json(conn, %{lobby_id: lobby_id})
  end

  def decline(conn, %{"id" => id}) do
    with :ok <- Invitations.decline(conn.assigns.user_id, id), do: send_resp(conn, 204, "")
  end
end
