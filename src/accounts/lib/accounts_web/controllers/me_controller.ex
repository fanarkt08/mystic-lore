defmodule MlAccountsWeb.MeController do
  use MlAccountsWeb, :controller
  alias MlAccounts.{Avatars, Profiles}
  alias MlAccountsWeb.UserJSON

  def show(conn, _params), do: json(conn, %{user: UserJSON.private(conn.assigns.current_user)})

  def update(conn, params) do
    with {:ok, user} <- MlAccounts.update_profile(conn.assigns.current_user, params) do
      json(conn, %{user: UserJSON.private(user)})
    end
  end

  @doc "Préférences : changements partiels ; un thème VIP exige la formule VIP effective (billing)."
  def update_preferences(conn, params) do
    with {:ok, user} <- MlAccounts.update_preferences(conn.assigns.current_user, params) do
      json(conn, %{user: UserJSON.private(user)})
    end
  end

  @doc "Accueil guidé : `completed`, `skipped` (plus proposé) ou `pending` (relancé depuis les paramètres)."
  def update_onboarding(conn, params) do
    with {:ok, user} <- MlAccounts.set_onboarding(conn.assigns.current_user, params["status"]) do
      json(conn, %{user: UserJSON.private(user)})
    end
  end

  @doc "Image d'avatar envoyée telle quelle (corps brut, 2 Mo au plus) ; son type vient de ses octets."
  def upload_avatar(conn, _params) do
    case read_body(conn, length: MlAccounts.Avatars.max_bytes()) do
      {:ok, bytes, conn} ->
        with {:ok, user} <- Avatars.upload(conn.assigns.current_user, bytes),
             do: json(conn, %{user: UserJSON.private(user)})

      {:more, _partial, _conn} ->
        {:error, {:invalid, %{avatar: ["must be at most 2 MB"]}}}

      {:error, _reason} ->
        {:error, {:invalid, %{avatar: ["is not a valid image file"]}}}
    end
  end

  def choose_crest(conn, params) do
    with {:ok, user} <- Avatars.choose_crest(conn.assigns.current_user, params["crest"]),
         do: json(conn, %{user: UserJSON.private(user)})
  end

  def remove_avatar(conn, _params) do
    with {:ok, user} <- Avatars.remove(conn.assigns.current_user),
         do: json(conn, %{user: UserJSON.private(user)})
  end

  @doc "Mon profil tel que le voit un visiteur, un membre ou un ami : même filtrage que la vraie page."
  def profile_preview(conn, params) do
    if params["as"] in Profiles.preview_readers() do
      reader = String.to_existing_atom(params["as"])
      json(conn, %{profile: Profiles.view(conn.assigns.current_user, reader)})
    else
      {:error, {:invalid, %{as: ["is invalid"]}}}
    end
  end

  # La session courante (en-tête `x-session-token`, facultatif) survit au changement ; toutes les autres sont révoquées.
  def update_password(conn, params) do
    with {:ok, _user} <-
           MlAccounts.change_password(conn.assigns.current_user, params, session_token(conn)) do
      send_resp(conn, 204, "")
    end
  end

  @doc "Changement d'e-mail : lien de confirmation envoyé à la nouvelle adresse (mot de passe exigé)."
  def change_email(conn, params) do
    with :ok <- MlAccounts.request_email_change(conn.assigns.current_user, params),
         do: send_resp(conn, 204, "")
  end

  def confirm_email(conn, params) do
    with {:ok, user} <-
           MlAccounts.confirm_email_change(conn.assigns.current_user, params["token"]),
         do: json(conn, %{user: UserJSON.private(user)})
  end

  defp session_token(conn), do: conn |> get_req_header("x-session-token") |> List.first()
end
