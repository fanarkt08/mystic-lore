defmodule MlMultiplayerWeb.ChatController do
  use MlMultiplayerWeb, :controller
  alias MlMultiplayer.{Accounts, Chat}
  alias MlMultiplayerWeb.LobbyJSON

  action_fallback MlMultiplayerWeb.FallbackController

  def index(conn, %{"id" => id} = params) do
    with {:ok, page} <- Chat.list(conn.assigns.user_id, id, params["before"]) do
      users = Accounts.users(Enum.map(page.entries, & &1.user_id))

      json(conn, %{
        entries: Enum.map(page.entries, &LobbyJSON.message(&1, users)),
        next_before: page.next_before
      })
    end
  end

  # Un membre restreint par le staff n'écrit plus dans le chat (403 `restricted` + date de fin) ; accounts
  # injoignable : refus (503).
  def create(conn, %{"id" => id} = params) do
    with :ok <- Accounts.check_not_restricted(conn.assigns.user_id),
         {:ok, message} <- Chat.post(conn.assigns.user_id, id, params) do
      users = Accounts.users([message.user_id])
      conn |> put_status(:created) |> json(%{message: LobbyJSON.message(message, users)})
    end
  end
end
