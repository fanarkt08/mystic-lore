defmodule MlStudioWeb.Router do
  use MlStudioWeb, :router

  # Every /api route acts for the member carried by the internal token (called by `web`).
  pipeline :api do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal, user: :required
  end

  # Service-to-service calls (internal token, no user): personal data, accounts only.
  pipeline :service do
    plug :accepts, ["json"]
    plug MlShared.Plug.Internal
  end

  get "/healthz", MlStudioWeb.HealthController, :show

  scope "/api/internal", MlStudioWeb do
    pipe_through :service
    get "/users/:id/export", PrivacyController, :export
    delete "/users/:id", PrivacyController, :delete
  end

  scope "/api", MlStudioWeb do
    pipe_through :api

    get "/ai", AIController, :info
    get "/me/ai-settings", AIController, :settings
    put "/me/ai-settings", AIController, :update_settings
    get "/me/generations", AIController, :history

    get "/projects", ProjectController, :index
    post "/projects", ProjectController, :create
    get "/projects/:id", ProjectController, :show
    patch "/projects/:id", ProjectController, :update
    delete "/projects/:id", ProjectController, :delete

    post "/projects/:id/modules", ContentController, :create_module
    put "/projects/:id/modules/order", ContentController, :order_modules
    patch "/projects/:id/modules/:module_id", ContentController, :update_module
    delete "/projects/:id/modules/:module_id", ContentController, :delete_module
    post "/projects/:id/modules/:module_id/lessons", ContentController, :create_lesson
    put "/projects/:id/modules/:module_id/lessons/order", ContentController, :order_lessons
    patch "/projects/:id/lessons/:lesson_id", ContentController, :update_lesson
    delete "/projects/:id/lessons/:lesson_id", ContentController, :delete_lesson

    post "/projects/:id/collaborators", CollaboratorController, :create
    patch "/projects/:id/collaborators/:user_id", CollaboratorController, :update
    delete "/projects/:id/collaborators/:user_id", CollaboratorController, :delete

    get "/projects/:id/versions", VersionController, :index
    post "/projects/:id/versions", VersionController, :create
    post "/projects/:id/versions/:version_id/restore", VersionController, :restore

    # media of the video lessons (video = raw bytes, captions = WebVTT text)
    post "/projects/:id/lessons/:lesson_id/video", MediaController, :upload_video
    post "/projects/:id/lessons/:lesson_id/captions", MediaController, :create_captions
    delete "/projects/:id/lessons/:lesson_id/captions/:lang", MediaController, :delete_captions
    get "/projects/:id/media/:media_id", MediaController, :show

    # files of the version published in learning, for any member (web proxy /media/studio/:media_id)
    get "/media/:media_id", MediaController, :published

    post "/projects/:id/images", ImageController, :create
    get "/projects/:id/images/:image_id", ImageController, :show
    patch "/projects/:id/images/:image_id", ImageController, :update
    delete "/projects/:id/images/:image_id", ImageController, :delete

    get "/projects/:id/checks", PublishingController, :checks
    put "/projects/:id/attestations", PublishingController, :attest
    post "/projects/:id/submit", PublishingController, :submit
    post "/projects/:id/withdraw", PublishingController, :withdraw

    get "/projects/:id/generations", AIController, :index
    post "/projects/:id/generations", AIController, :create
    post "/generations/:id/cancel", AIController, :cancel
    post "/generations/:id/retry", AIController, :retry
    post "/generations/:id/apply", AIController, :apply

    get "/moderation/queue", ModerationController, :queue
    get "/moderation/projects/:id", ModerationController, :show
    post "/moderation/projects/:id/approve", ModerationController, :approve
    post "/moderation/projects/:id/reject", ModerationController, :reject
    post "/moderation/projects/:id/retry-import", ModerationController, :retry_import
    # staff indicators
    get "/admin/stats", ModerationController, :stats
  end
end
