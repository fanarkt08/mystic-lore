defmodule MlAccountsWeb.Router do
  use MlAccountsWeb, :router

  # Appel de service à service : jeton interne signé obligatoire.
  pipeline :service do
    plug MlShared.Plug.Internal
  end

  # Route « utilisateur » : le jeton interne doit porter un membre existant (`conn.assigns.current_user`).
  pipeline :user do
    plug MlShared.Plug.Internal, user: :required
    plug :fetch_current_user
  end

  # Staff (moderator, admin) : rôle lu en base à chaque requête ; admin seulement pour `:admin`.
  pipeline :staff do
    plug MlShared.Plug.Internal, user: :required
    plug :fetch_current_user
    plug :require_role, ~w(moderator admin)
  end

  pipeline :admin do
    plug MlShared.Plug.Internal, user: :required
    plug :fetch_current_user
    plug :require_role, ~w(admin)
  end

  get "/healthz", MlAccountsWeb.HealthController, :show

  scope "/api", MlAccountsWeb do
    pipe_through :service

    post "/users", UserController, :create
    get "/users", UserController, :index
    post "/users/confirm", UserController, :confirm
    post "/users/resend-confirmation", UserController, :resend_confirmation
    get "/users/by-username/:username", UserController, :show
    # profil filtré selon le lecteur (membre du jeton, ou visiteur) et image d'avatar actuelle
    get "/users/by-username/:username/profile", UserController, :profile
    get "/avatars/:name", UserController, :avatar
    # lecture interne (autres services) : rôle et état du compte, jamais l'e-mail
    get "/internal/users/:id", UserController, :internal
    # journal d'audit central : écriture par les autres services (appelants autorisés seulement)
    post "/internal/audit", AuditController, :create

    # e-mail demandé par le centre de notifications (appelant notifications seulement, modèle en liste blanche)
    post "/internal/users/:id/notification-email", NotificationEmailController, :create
    post "/sessions", SessionController, :create
    post "/sessions/2fa", SessionController, :create_two_factor
    get "/sessions/current", SessionController, :show
    delete "/sessions/current", SessionController, :delete
    post "/password-resets", PasswordResetController, :create
    get "/password-resets/:token", PasswordResetController, :show
    post "/password-resets/:token", PasswordResetController, :update

    # formulaire de contact : visiteur (jeton sans membre) ou membre
    post "/support/requests", SupportController, :create
  end

  scope "/api", MlAccountsWeb do
    pipe_through :user

    get "/users/search", UserController, :search
    get "/me", MeController, :show
    patch "/me", MeController, :update
    # profil enrichi et préférences
    patch "/me/preferences", MeController, :update_preferences
    put "/me/avatar", MeController, :upload_avatar
    put "/me/avatar/crest", MeController, :choose_crest
    delete "/me/avatar", MeController, :remove_avatar
    get "/me/profile-preview", MeController, :profile_preview
    put "/me/password", MeController, :update_password
    post "/me/email", MeController, :change_email
    post "/me/email/confirm", MeController, :confirm_email
    get "/me/sessions", SessionController, :index
    delete "/me/sessions", SessionController, :revoke_others
    delete "/me/sessions/:id", SessionController, :revoke
    get "/me/2fa", TwoFactorController, :show
    post "/me/2fa/setup", TwoFactorController, :setup
    post "/me/2fa/enable", TwoFactorController, :enable
    post "/me/2fa/disable", TwoFactorController, :disable
    post "/me/2fa/recovery-codes", TwoFactorController, :recovery_codes
    # données personnelles : export (réauthentification) et suppression programmée du compte
    post "/me/exports", PrivacyController, :create_export
    get "/me/exports", PrivacyController, :exports
    get "/me/exports/:id/download", PrivacyController, :download
    post "/me/deletion", PrivacyController, :schedule_deletion
    delete "/me/deletion", PrivacyController, :cancel_deletion
    # sanctions du membre et appel motivé
    get "/me/sanctions", SanctionController, :mine
    post "/me/sanctions/:id/appeal", SanctionController, :appeal
    # accueil guidé (terminé, passé, relancé) et demandes de support du membre
    put "/me/onboarding", MeController, :update_onboarding
    get "/me/support/requests", SupportController, :mine
  end

  # Administration et modération
  scope "/api/admin", MlAccountsWeb do
    pipe_through :staff

    get "/stats", StaffController, :stats
    get "/users", StaffController, :index
    get "/users/:id", StaffController, :show
    post "/users/:id/avatar/reset", StaffController, :reset_avatar
    post "/users/:id/sanctions", SanctionController, :create
    post "/sanctions/:id/lift", SanctionController, :lift
    get "/appeals", SanctionController, :appeals
    post "/appeals/:id/decide", SanctionController, :decide
    get "/incidents", IncidentController, :index
    post "/incidents", IncidentController, :create
    get "/incidents/:id", IncidentController, :show
    post "/incidents/:id/updates", IncidentController, :update

    # support : liste, détail (consultation auditée), réponse par e-mail, statut et note interne
    get "/support/requests", SupportController, :index
    get "/support/requests/:id", SupportController, :show
    post "/support/requests/:id/replies", SupportController, :reply
    patch "/support/requests/:id", SupportController, :update
  end

  scope "/api/admin", MlAccountsWeb do
    pipe_through :admin

    put "/users/:id/role", StaffController, :set_role
    get "/audit", AuditController, :index
    get "/audit/export", AuditController, :export
    # effacement immédiat d'une demande de support (ex. demande d'un visiteur), audité
    delete "/support/requests/:id", SupportController, :delete
  end

  # Boîte aux lettres Swoosh (dev uniquement) : e-mails (confirmation, réinitialisation, changement d'adresse) envoyés en local.
  if Application.compile_env(:accounts, :dev_routes) do
    forward "/dev/mailbox", Plug.Swoosh.MailboxPreview
  end

  # Un compte dont la suppression est due (ou faite) n'agit plus.
  defp fetch_current_user(conn, _opts) do
    with %MlAccounts.User{} = user <- MlAccounts.get_user(conn.assigns.user_id),
         false <- MlAccounts.Privacy.deleting?(user) do
      assign(conn, :current_user, user)
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end

  defp require_role(conn, roles) do
    if conn.assigns.current_user.role in roles,
      do: conn,
      else: conn |> put_status(403) |> json(%{error: "forbidden"}) |> halt()
  end
end
