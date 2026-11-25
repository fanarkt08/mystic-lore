defmodule MlMultiplayerWeb.Router do
  use MlMultiplayerWeb, :router

  # Toute route /api exige un jeton interne portant un utilisateur (UUID) : l'autorisation de chaque action
  # repose sur `conn.assigns.user_id`, jamais sur un identifiant transmis dans le corps ou l'URL.
  pipeline :api do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal, user: :required
    plug :canonical_user_id
  end

  # Appels de service à service (jeton interne, sans utilisateur) : données personnelles, appelant accounts seulement.
  pipeline :service do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal
  end

  get "/healthz", MlMultiplayerWeb.HealthController, :show

  scope "/api/internal", MlMultiplayerWeb do
    pipe_through :service
    get "/users/:id/export", PrivacyController, :export
    delete "/users/:id", PrivacyController, :delete
  end

  scope "/api", MlMultiplayerWeb do
    pipe_through :api

    get "/lobbies", LobbyController, :index
    post "/lobbies", LobbyController, :create
    get "/me/lobbies", LobbyController, :mine
    get "/lobbies/:id", LobbyController, :show
    post "/lobbies/:id/join", LobbyController, :join
    post "/lobbies/:id/leave", LobbyController, :leave
    post "/lobbies/:id/ready", LobbyController, :ready
    post "/lobbies/:id/start", LobbyController, :start
    post "/lobbies/:id/transfer", LobbyController, :transfer
    post "/lobbies/:id/kick", LobbyController, :kick
    post "/lobbies/:id/requests/:user_id/approve", LobbyController, :approve
    post "/lobbies/:id/requests/:user_id/decline", LobbyController, :decline
    post "/lobbies/:id/heartbeat", LobbyController, :heartbeat
    post "/lobbies/:id/attempts", LobbyController, :attempt
    post "/lobbies/:id/reports", LobbyController, :report

    get "/lobbies/:id/messages", ChatController, :index
    post "/lobbies/:id/messages", ChatController, :create

    get "/me/invites", InviteController, :index
    post "/lobbies/:id/invites", InviteController, :create
    post "/invites/:id/accept", InviteController, :accept
    post "/invites/:id/decline", InviteController, :decline

    post "/lobbies/:id/links", LinkController, :create
    delete "/lobbies/:id/links/:link_id", LinkController, :revoke
    post "/links/preview", LinkController, :preview
    post "/links/join", LinkController, :join

    # indicateurs du staff
    get "/admin/stats", AdminController, :stats
  end

  defp canonical_user_id(conn, _opts) do
    case MlMultiplayer.cast_uuid(conn.assigns.user_id) do
      {:ok, id} -> assign(conn, :user_id, id)
      :error -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end
end
