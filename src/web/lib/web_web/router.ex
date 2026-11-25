defmodule MysticWeb.Router do
  use MysticWeb, :router

  require MysticWeb.Routes.Multiplayer
  require MysticWeb.Routes.Community
  require MysticWeb.Routes.Security
  require MysticWeb.Routes.Gamification
  require MysticWeb.Routes.Studio
  require MysticWeb.Routes.Privacy
  require MysticWeb.Routes.Admin
  require MysticWeb.Routes.Pages

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MysticWeb.Layouts, :root}
    plug :protect_from_forgery
    plug MysticWeb.SecurityHeaders
    plug MysticWeb.Locale
  end

  # Offline lessons: JSON for the browser's script, CSRF token required for the synchronization.
  pipeline :offline_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug MysticWeb.SecurityHeaders
    plug MysticWeb.Locale
  end

  get "/healthz", MysticWeb.HealthController, :show

  # PWA: service worker at the root (its scope is the whole site) and the application manifest
  get "/sw.js", MysticWeb.OfflineController, :service_worker
  get "/manifest.webmanifest", MysticWeb.OfflineController, :manifest

  scope "/offline", MysticWeb do
    pipe_through :offline_api
    get "/session", OfflineController, :session
    get "/packages/:lesson_id", OfflineController, :package
    post "/sync", OfflineController, :sync
  end

  scope "/", MysticWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
    get "/register", RegistrationController, :new
    post "/register", RegistrationController, :create
    post "/confirm", ConfirmationController, :resend
    get "/confirm/:token", ConfirmationController, :show
    post "/confirm/:token", ConfirmationController, :create

    # langue choisie par un visiteur (sélecteur du pied de page) ; avatars téléversés, relayés depuis accounts
    post "/locale", LocaleController, :update
    get "/media/avatars/:key", AvatarController, :show

    # pièces jointes des conversations, relayées depuis social (membres seulement, vérifié par social)
    get "/media/attachments/:id", AttachmentController, :show

    # page hors ligne : générique, mise en cache par le service worker
    get "/offline", OfflineController, :shell
    MysticWeb.Routes.Multiplayer.browser()
    MysticWeb.Routes.Community.browser()
    MysticWeb.Routes.Security.browser()
    MysticWeb.Routes.Gamification.browser()
    MysticWeb.Routes.Studio.browser()
    MysticWeb.Routes.Privacy.browser()
    MysticWeb.Routes.Admin.browser()
    MysticWeb.Routes.Pages.browser()

    # Préférences appliquées après l'identification du membre (langue, fuseau, thème, accessibilité).
    live_session :public,
      on_mount: [MysticWeb.Locale, {MysticWeb.Auth, :mount_current_user}, MysticWeb.Preferences] do
      live "/", HomeLive
      live "/adventures", AdventureLive.Index
      live "/adventures/:slug", AdventureLive.Show
      # profil ouvert aux visiteurs : accounts filtre ce qu'ils voient
      live "/members/:username", MemberLive
      MysticWeb.Routes.Multiplayer.public()
      MysticWeb.Routes.Community.public()
      MysticWeb.Routes.Security.public()
      MysticWeb.Routes.Gamification.public()
      MysticWeb.Routes.Studio.public()
      # pages juridiques, aide, contact
      MysticWeb.Routes.Pages.public()
    end

    live_session :member,
      on_mount: [MysticWeb.Locale, {MysticWeb.Auth, :require_user}, MysticWeb.Preferences] do
      live "/dashboard", DashboardLive
      live "/learn/:slug/:lesson_id", LearnLive
      live "/membership", MembershipLive
      live "/membership/local-checkout/:session_id", LocalCheckoutLive
      live "/membership/success", CheckoutResultLive, :success
      live "/membership/cancel", CheckoutResultLive, :cancel
      live "/friends", FriendsLive
      live "/messages", MessagesLive, :index
      live "/messages/new", MessagesLive, :new
      live "/messages/:id", MessagesLive, :show
      live "/settings", SettingsLive
      live "/settings/:section", SettingsLive

      # centre de notifications (service notifications) : liste, lecture ; réglages dans /settings/notifications
      live "/notifications", NotificationsLive
      MysticWeb.Routes.Multiplayer.member()
      MysticWeb.Routes.Community.member()
      MysticWeb.Routes.Security.member()
      MysticWeb.Routes.Gamification.member()
      MysticWeb.Routes.Studio.member()
      MysticWeb.Routes.Admin.member()
      # accueil guidé
      MysticWeb.Routes.Pages.member()
    end
  end
end
