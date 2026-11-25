defmodule MlLearningWeb.Router do
  use MlLearningWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Jeton interne exigé ; utilisateur optionnel (catalogue) ou obligatoire.
  pipeline :service do
    plug MlShared.Plug.Internal
    plug :user_uuid
  end

  pipeline :user do
    plug MlShared.Plug.Internal, user: :required
    plug :user_uuid
  end

  scope "/", MlLearningWeb do
    pipe_through :api
    get "/healthz", HealthController, :show
  end

  scope "/api", MlLearningWeb do
    pipe_through [:api, :service]
    get "/adventures", AdventureController, :index
    get "/adventures/:slug", AdventureController, :show
    # profil public de progression : lisible par tout appelant (membre quelconque ou anonyme)
    get "/users/:id/profile", GamificationController, :profile
    # appels de service à service uniquement (jeton interne, sans utilisateur)
    post "/internal/xp", InternalXpController, :create
    post "/internal/adventures/import", ImportController, :create
    # données personnelles : appelant accounts uniquement (403 sinon)
    get "/internal/users/:id/export", PrivacyController, :export
    delete "/internal/users/:id", PrivacyController, :delete
  end

  scope "/api", MlLearningWeb do
    pipe_through [:api, :user]
    post "/adventures/:slug/enroll", AdventureController, :enroll
    get "/lessons/:id", LessonController, :show
    # paquet hors ligne d'une leçon premium
    get "/lessons/:id/offline", LessonController, :offline
    post "/lessons/:id/submit", LessonController, :submit
    post "/lessons/:id/complete", LessonController, :complete
    post "/lessons/:id/simulate", LessonController, :simulate
    put "/lessons/:id/notes", LessonController, :notes
    put "/lessons/:id/draft", LessonController, :draft
    get "/me/dashboard", DashboardController, :show
    get "/me/achievements", GamificationController, :achievements
    put "/me/badges/equipped", GamificationController, :equip
    get "/me/quests", GamificationController, :quests
    # indicateurs du staff
    get "/admin/stats", AdminController, :stats
  end

  # Le `sub` du jeton est un identifiant d'accounts : un UUID, sinon 401 comme pour un jeton invalide.
  defp user_uuid(%{assigns: %{user_id: nil}} = conn, _opts), do: conn

  defp user_uuid(conn, _opts) do
    case MlLearning.cast_uuid(conn.assigns.user_id) do
      {:ok, user_id} -> assign(conn, :user_id, user_id)
      :error -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end
end
