defmodule MlCommunityWeb.Router do
  use MlCommunityWeb, :router

  # Lecture : jeton interne obligatoire, utilisateur facultatif (visiteur = contenus publics seulement).
  pipeline :public do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal
    plug :canonical_user_id
  end

  # Actions : le jeton doit porter un utilisateur.
  pipeline :member do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal, user: :required
    plug :canonical_user_id
  end

  # Appels de service à service (jeton interne, sans utilisateur) : données personnelles, appelant accounts seulement.
  pipeline :service do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal
  end

  get "/healthz", MlCommunityWeb.HealthController, :show

  scope "/api/internal", MlCommunityWeb do
    pipe_through :service
    get "/users/:id/export", PrivacyController, :export
    delete "/users/:id", PrivacyController, :delete
  end

  scope "/api", MlCommunityWeb do
    pipe_through :public

    get "/categories", DiscussionController, :categories
    get "/discussions", DiscussionController, :index
    get "/discussions/:slug", DiscussionController, :show
  end

  scope "/api", MlCommunityWeb do
    pipe_through :member

    post "/discussions", DiscussionController, :create
    patch "/discussions/:slug", DiscussionController, :update
    delete "/discussions/:slug", DiscussionController, :delete
    put "/discussions/:slug/follow", DiscussionController, :follow
    delete "/discussions/:slug/follow", DiscussionController, :unfollow
    put "/discussions/:slug/vote", DiscussionController, :vote
    delete "/discussions/:slug/vote", DiscussionController, :unvote
    put "/discussions/:slug/solution", DiscussionController, :set_solution
    delete "/discussions/:slug/solution", DiscussionController, :clear_solution

    post "/discussions/:slug/replies", ReplyController, :create
    patch "/replies/:id", ReplyController, :update
    delete "/replies/:id", ReplyController, :delete
    put "/replies/:id/vote", ReplyController, :vote
    delete "/replies/:id/vote", ReplyController, :unvote

    post "/reports", ReportController, :create

    post "/moderation/discussions/:id", ModerationController, :discussion
    post "/moderation/replies/:id", ModerationController, :reply
    get "/moderation/reports", ModerationController, :reports
    get "/moderation/reports/:id", ModerationController, :show
    get "/admin/stats", ModerationController, :stats
    post "/moderation/reports/:id/resolve", ModerationController, :resolve
  end

  # Toute autorisation repose sur cet identifiant : on le normalise (UUID minuscule) ou on refuse.
  defp canonical_user_id(%{assigns: %{user_id: nil}} = conn, _opts), do: conn

  defp canonical_user_id(conn, _opts) do
    case Ecto.UUID.cast(conn.assigns.user_id) do
      {:ok, id} -> assign(conn, :user_id, id)
      :error -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end
end
