defmodule MlNotificationsWeb.Router do
  use MlNotificationsWeb, :router

  # Routes du membre (appelées par web) : le jeton porte le membre.
  pipeline :api do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal, user: :required
    plug :canonical_user_id
  end

  # Appels de service à service (jeton interne, sans membre) : producteurs, et accounts (données personnelles).
  pipeline :service do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal
  end

  get "/healthz", MlNotificationsWeb.HealthController, :show

  scope "/api/internal", MlNotificationsWeb do
    pipe_through :service
    # chaque producteur ne crée que ses catégories (403 sinon)
    post "/notifications", InternalController, :create
    post "/notifications/read", InternalController, :read
    post "/notifications/clear-between", InternalController, :clear_between
    # données personnelles : appelant accounts uniquement (403 sinon)
    get "/users/:id/export", PrivacyController, :export
    delete "/users/:id", PrivacyController, :delete
  end

  scope "/api", MlNotificationsWeb do
    pipe_through :api

    get "/me/notifications", NotificationController, :index
    get "/me/notifications/unread-count", NotificationController, :unread_count
    post "/me/notifications/read-all", NotificationController, :read_all
    get "/me/notifications/:id", NotificationController, :show
    post "/me/notifications/:id/read", NotificationController, :read
    get "/me/notification-settings", SettingsController, :show
    patch "/me/notification-settings", SettingsController, :update
  end

  # Toute autorisation repose sur cet identifiant : on le normalise (UUID minuscule) ou on refuse.
  defp canonical_user_id(conn, _opts) do
    case Ecto.UUID.cast(conn.assigns.user_id) do
      {:ok, id} -> assign(conn, :user_id, id)
      :error -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end
end
