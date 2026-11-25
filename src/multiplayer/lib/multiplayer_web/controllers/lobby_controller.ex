defmodule MlMultiplayerWeb.LobbyController do
  use MlMultiplayerWeb, :controller
  alias MlMultiplayer.{Accounts, Lobbies, Presence}
  alias MlMultiplayerWeb.LobbyJSON

  action_fallback MlMultiplayerWeb.FallbackController

  def index(conn, params) do
    with {:ok, page} <- Lobbies.list_open(conn.assigns.user_id, page(params["page"])) do
      users = Accounts.users(Enum.map(page.entries, & &1.lobby.host_id))

      json(conn, %{
        entries: Enum.map(page.entries, &LobbyJSON.summary(&1, users)),
        page: page.page,
        total_pages: page.total_pages,
        total: page.total
      })
    end
  end

  def mine(conn, _params) do
    entries = Lobbies.list_mine(conn.assigns.user_id)
    users = Accounts.users(Enum.map(entries, & &1.lobby.host_id))
    json(conn, %{lobbies: Enum.map(entries, &LobbyJSON.summary(&1, users))})
  end

  def create(conn, params) do
    with {:ok, lobby} <- Lobbies.create(conn.assigns.user_id, params) do
      conn |> put_status(:created) |> render_detail(lobby.id)
    end
  end

  def show(conn, %{"id" => id}), do: render_detail(conn, id)

  def join(conn, %{"id" => id}) do
    with {:ok, outcome} <- Lobbies.join(conn.assigns.user_id, id),
         do: json(conn, %{status: outcome})
  end

  def leave(conn, %{"id" => id}) do
    with :ok <- Lobbies.leave(conn.assigns.user_id, id), do: send_resp(conn, 204, "")
  end

  def ready(conn, %{"id" => id} = params) do
    case params["ready"] do
      ready when is_boolean(ready) ->
        with :ok <- Lobbies.set_ready(conn.assigns.user_id, id, ready),
             do: send_resp(conn, 204, "")

      _ ->
        {:error, {:invalid, %{ready: ["must be true or false"]}}}
    end
  end

  def start(conn, %{"id" => id}) do
    with {:ok, match} <- Lobbies.start(conn.assigns.user_id, id) do
      conn |> put_status(:created) |> json(%{match_id: match.id})
    end
  end

  def transfer(conn, %{"id" => id} = params) do
    with :ok <- Lobbies.transfer(conn.assigns.user_id, id, params["user_id"]),
         do: send_resp(conn, 204, "")
  end

  def kick(conn, %{"id" => id} = params) do
    with :ok <- Lobbies.kick(conn.assigns.user_id, id, params["user_id"]),
         do: send_resp(conn, 204, "")
  end

  def approve(conn, %{"id" => id, "user_id" => user_id}) do
    with :ok <- Lobbies.approve(conn.assigns.user_id, id, user_id), do: send_resp(conn, 204, "")
  end

  def decline(conn, %{"id" => id, "user_id" => user_id}) do
    with :ok <- Lobbies.decline(conn.assigns.user_id, id, user_id), do: send_resp(conn, 204, "")
  end

  def heartbeat(conn, %{"id" => id}) do
    with :ok <- Presence.heartbeat(conn.assigns.user_id, id), do: send_resp(conn, 204, "")
  end

  def attempt(conn, %{"id" => id} = params) do
    with {:ok, match} <- Lobbies.attempt(conn.assigns.user_id, id, params["sequence"]) do
      users = Accounts.users(match["players"])
      json(conn, %{match: Map.update!(match, "players", &Enum.map(&1, fn uid -> users[uid] end))})
    end
  end

  def report(conn, %{"id" => id} = params) do
    with {:ok, report_id} <- Lobbies.report(conn.assigns.user_id, id, params) do
      conn |> put_status(:created) |> json(%{id: report_id})
    end
  end

  defp render_detail(conn, id) do
    with {:ok, detail} <- Lobbies.detail(conn.assigns.user_id, id) do
      json(conn, LobbyJSON.detail(detail, Accounts.users(LobbyJSON.user_ids(detail))))
    end
  end

  # page invalide → 1 ; au-delà de la dernière → liste vide
  defp page(value) do
    case Integer.parse(to_string(value || "1")) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end
end
