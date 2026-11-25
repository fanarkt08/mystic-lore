defmodule MlSocialWeb.Router do
  use MlSocialWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal, user: :required
    plug :canonical_user_id
  end

  # appels de service à service (jeton interne, sans utilisateur) : relations et permissions utilisées par
  # accounts, multiplayer, community et studio
  pipeline :service do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal
  end

  get "/healthz", MlSocialWeb.HealthController, :show

  scope "/api/internal", MlSocialWeb do
    pipe_through :service
    get "/relationship", InternalController, :relationship
    get "/blocks/:user_id", InternalController, :blocks
    get "/can-contact", InternalController, :can_contact
    get "/users/:user_id/mutes", InternalController, :mutes
    # données personnelles : appelant accounts uniquement (403 sinon)
    get "/users/:id/export", PrivacyController, :export
    delete "/users/:id", PrivacyController, :delete
  end

  scope "/api", MlSocialWeb do
    pipe_through :api

    get "/me/friends", FriendController, :index
    get "/me/friend-requests", FriendController, :requests
    post "/friend-requests", FriendController, :create_request
    post "/friend-requests/:id/accept", FriendController, :accept
    post "/friend-requests/:id/decline", FriendController, :decline
    delete "/friends/:user_id", FriendController, :delete
    get "/me/blocks", FriendController, :blocks
    post "/blocks", FriendController, :block
    delete "/blocks/:user_id", FriendController, :unblock

    get "/me/conversations", ConversationController, :index
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    get "/conversations/:id/messages", ConversationController, :messages
    post "/conversations/:id/messages", ConversationController, :send_message
    post "/conversations/:id/read", ConversationController, :read
    put "/conversations/:id/mute", ConversationController, :mute
    delete "/conversations/:id/mute", ConversationController, :unmute
    get "/me/unread", ConversationController, :unread
    get "/attachments/:id", AttachmentController, :show

    post "/groups", GroupController, :create
    patch "/conversations/:id", GroupController, :rename
    post "/conversations/:id/members", GroupController, :add_member
    delete "/conversations/:id/members/:user_id", GroupController, :remove_member
    post "/conversations/:id/leave", GroupController, :leave

    get "/me/settings", SettingsController, :show
    patch "/me/settings", SettingsController, :update

    post "/reports", ReportController, :create

    # staff : aucune de ces routes ne lit une conversation
    get "/moderation/reports", ModerationController, :index
    get "/moderation/reports/:id", ModerationController, :show
    post "/moderation/reports/:id/evidence", ModerationController, :evidence
    post "/moderation/reports/:id/attachment", ModerationController, :attachment
    post "/moderation/reports/:id/resolve", ModerationController, :resolve
    get "/admin/stats", ModerationController, :stats
  end

  # Toute autorisation repose sur cet identifiant : on le normalise (UUID minuscule) ou on refuse.
  defp canonical_user_id(conn, _opts) do
    case Ecto.UUID.cast(conn.assigns.user_id) do
      {:ok, id} -> assign(conn, :user_id, id)
      :error -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end
end
