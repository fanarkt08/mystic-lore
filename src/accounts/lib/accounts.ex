defmodule MlAccounts do
  @moduledoc """
  Comptes : inscription, confirmation d'e-mail, sessions, verrouillage des connexions, profils et mots de passe.
  Les jetons ne sont renvoyés qu'une fois et seul leur SHA-256 est stocké.
  """
  import Ecto.Query
  require Logger

  alias MlAccounts.{
    ConfirmationToken,
    LoginChallenge,
    LoginFailure,
    Mailer,
    Repo,
    Session,
    Throttle,
    TwoFactor,
    User,
    UserEmail,
    UserToken
  }

  @confirmation_days 7
  @session_days 30
  @max_failures 5
  @failure_window_minutes 15
  @confirmation_emails_per_hour 3
  @challenge_minutes 5
  @challenge_attempts 5
  @reset_minutes 60
  @reset_emails_per_hour 3
  @email_change_hours 24
  @email_changes_per_hour 3

  ## Inscription et confirmation d'e-mail

  def register(attrs) do
    with {:ok, user} <- attrs |> User.registration_changeset() |> Repo.insert() do
      send_confirmation(user)
      {:ok, user}
    end
  end

  @doc "Jeton valable 7 jours et à usage unique : confirmer supprime tous les jetons du membre."
  def confirm(token) when is_binary(token) do
    Repo.transact(fn ->
      valid =
        from t in ConfirmationToken,
          where: t.token_hash == ^hash(token) and t.inserted_at > ago(^@confirmation_days, "day"),
          select: t.user_id

      # DELETE ... RETURNING : deux confirmations concurrentes ne peuvent pas consommer le même jeton.
      case Repo.delete_all(valid) do
        {1, [user_id]} ->
          Repo.delete_all(from t in ConfirmationToken, where: t.user_id == ^user_id)
          User |> Repo.get!(user_id) |> User.confirm_changeset() |> Repo.update()

        {0, []} ->
          {:error, :not_found}
      end
    end)
  end

  def confirm(_), do: {:error, :not_found}

  @doc "Renvoie un lien de confirmation si le compte n'est pas confirmé, sans jamais révéler s'il existe."
  def resend_confirmation(email) when is_binary(email) do
    with %User{confirmed_at: nil} = user <- Repo.get_by(User, email: User.normalize(email)),
         recent =
           from(t in ConfirmationToken,
             where: t.user_id == ^user.id and t.inserted_at > ago(1, "hour")
           ),
         true <- Repo.aggregate(recent, :count) < @confirmation_emails_per_hour do
      send_confirmation(user)
    end

    :ok
  end

  def resend_confirmation(_), do: :ok

  defp send_confirmation(user) do
    {token, token_hash} = new_token()
    Repo.insert!(%ConfirmationToken{user_id: user.id, token_hash: token_hash})
    deliver(UserEmail.confirmation(user, token), user)
  end

  ## Connexion et sessions

  @doc "Ouvre une session, ou renvoie un challenge 2FA, et verrouille l'e-mail après 5 échecs en 15 minutes."
  def login(email, password, client \\ %{})

  def login(email, password, client) when is_binary(email) and is_binary(password) do
    email = User.normalize(email)

    with :ok <-
           Throttle.reserve(LoginFailure, :email, email, @max_failures, @failure_window_minutes) do
      user = Repo.get_by(User, email: email)

      if User.valid_password?(user, password) do
        Repo.delete_all(from f in LoginFailure, where: f.email == ^email)

        cond do
          MlAccounts.Privacy.deleting?(user) -> {:error, :account_deleted}
          is_nil(user.confirmed_at) -> {:error, :unconfirmed}
          TwoFactor.enabled?(user) -> {:two_factor, create_challenge(user), user}
          true -> {:ok, create_session(user, client), user}
        end
      else
        {:error, :invalid_credentials}
      end
    end
  end

  def login(_, _, _), do: {:error, :invalid_credentials}

  defp create_challenge(user) do
    Repo.delete_all(
      from c in LoginChallenge,
        where: c.user_id == ^user.id and c.inserted_at <= ago(^@challenge_minutes, "minute")
    )

    {token, token_hash} = new_token()
    Repo.insert!(%LoginChallenge{user_id: user.id, token_hash: token_hash})
    token
  end

  @doc "Termine une connexion 2FA avec un code TOTP ou de récupération, en réservant l'essai avant de le vérifier."
  def complete_two_factor_login(challenge, code, client \\ %{})

  def complete_two_factor_login(challenge, code, client) when is_binary(challenge) do
    attempt =
      from c in LoginChallenge,
        where: c.token_hash == ^hash(challenge) and c.attempts < @challenge_attempts,
        where: c.inserted_at > ago(^@challenge_minutes, "minute"),
        select: c

    case Repo.update_all(attempt, inc: [attempts: 1]) do
      {1, [challenge]} -> verify_challenge(challenge, code, client)
      {0, _} -> {:error, :not_found}
    end
  end

  def complete_two_factor_login(_, _, _), do: {:error, :not_found}

  defp verify_challenge(challenge, code, client) do
    user = Repo.get!(User, challenge.user_id)

    with :ok <- if(MlAccounts.Privacy.deleting?(user), do: {:error, :not_found}, else: :ok),
         :ok <- TwoFactor.verify(user, code),
         {1, _} <- Repo.delete_all(from c in LoginChallenge, where: c.id == ^challenge.id) do
      {:ok, create_session(user, client), user}
    else
      {:error, :invalid_code} -> {:error, :invalid_code, @challenge_attempts - challenge.attempts}
      {:error, :locked} -> {:error, :locked}
      {:error, :not_found} -> {:error, :not_found}
      {0, _} -> {:error, :not_found}
    end
  end

  defp create_session(user, client) do
    Repo.delete_all(
      from s in Session,
        where: s.user_id == ^user.id and s.last_used_at <= ago(^@session_days, "day")
    )

    {token, token_hash} = new_token()

    Repo.insert!(%Session{
      user_id: user.id,
      token_hash: token_hash,
      last_used_at: DateTime.utc_now(:second),
      user_agent: user_agent(client[:user_agent]),
      ip: anonymize_ip(client[:ip])
    })

    token
  end

  # Texte libre d'en-tête HTTP : octets invalides et caractères de contrôle retirés, 200 caractères au plus.
  defp user_agent(ua) when is_binary(ua) do
    ua
    |> String.replace_invalid("")
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.trim()
    |> String.slice(0, 200)
    |> case do
      "" -> nil
      ua -> ua
    end
  end

  defp user_agent(_), do: nil

  @doc false
  # IP anonymisée avant stockage : IPv4 → /24 (dernier octet à 0), IPv6 → /48 ; invalide → nil.
  def anonymize_ip(ip) when is_binary(ip) and byte_size(ip) <= 64 do
    with true <- String.valid?(ip),
         {:ok, address} <-
           ip |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      address |> truncate_ip() |> :inet.ntoa() |> to_string()
    else
      _ -> nil
    end
  end

  def anonymize_ip(_), do: nil

  defp truncate_ip({a, b, c, _}), do: {a, b, c, 0}
  # IPv4 encapsulée dans IPv6 (::ffff:a.b.c.d) : traitée comme IPv4
  defp truncate_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: truncate_ip({div(ab, 256), rem(ab, 256), div(cd, 256), 0})

  defp truncate_ip({a, b, c, _, _, _, _, _}), do: {a, b, c, 0, 0, 0, 0, 0}

  @doc "Renvoie le membre d'une session valide et prolonge son expiration glissante de 30 jours."
  def get_session_user(token) when is_binary(token) do
    valid =
      from s in Session,
        where: s.token_hash == ^hash(token) and s.last_used_at > ago(^@session_days, "day"),
        select: s.user_id

    with {1, [user_id]} <- Repo.update_all(valid, set: [last_used_at: DateTime.utc_now(:second)]),
         %User{} = user <- Repo.get(User, user_id),
         false <- MlAccounts.Privacy.deleting?(user) do
      user
    else
      _ -> nil
    end
  end

  def get_session_user(_), do: nil

  def revoke_session(token) when is_binary(token) do
    case Repo.delete_all(
           from s in Session, where: s.token_hash == ^hash(token), select: s.user_id
         ) do
      {1, [user_id]} -> sessions_revoked(user_id)
      {0, []} -> :ok
    end
  end

  def revoke_session(_), do: :ok

  @doc "Sessions valides du membre, la plus récemment utilisée d'abord, avec `current` : celle de `current_token`."
  def list_sessions(%User{id: user_id}, current_token) do
    current = if is_binary(current_token), do: hash(current_token)

    Repo.all(
      from s in Session,
        where: s.user_id == ^user_id and s.last_used_at > ago(^@session_days, "day"),
        order_by: [desc: s.last_used_at, desc: s.inserted_at]
    )
    |> Enum.map(&{&1, &1.token_hash == current})
  end

  @doc "Révoque une session du membre, jamais la session courante."
  def revoke_user_session(%User{id: user_id}, session_id, current_token) do
    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         %Session{} = session <- Repo.get_by(Session, id: session_id, user_id: user_id) do
      if is_binary(current_token) and session.token_hash == hash(current_token) do
        {:error, :current_session}
      else
        Repo.delete_all(from s in Session, where: s.id == ^session.id)
        MlAccounts.Notify.security(user_id, "sessions_revoked", %{count: 1})
        sessions_revoked(user_id)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Révoque toutes les sessions du membre sauf celle de `current_token` (toutes s'il est absent)."
  def revoke_other_sessions(%User{} = user, current_token) do
    case Repo.delete_all(sessions_to_revoke(user, current_token)) do
      {0, _} ->
        :ok

      {count, _} ->
        MlAccounts.Notify.security(user.id, "sessions_revoked", %{count: count})
        sessions_revoked(user.id)
    end
  end

  defp sessions_revoked(user_id) do
    MlShared.Events.broadcast(MlShared.Events.user(user_id), {:sessions_revoked, user_id})
    :ok
  end

  @doc """
  Mot de passe actuel d'un membre connecté (changement de mot de passe ou d'e-mail, 2FA) : après 5 échecs en
  15 minutes, `{:error, :locked}` sans vérifier ; un succès remet le compteur à zéro.
  """
  def verify_password(%User{} = user, password) do
    key = "password:" <> user.id

    with :ok <- Throttle.reserve(key, @max_failures, @failure_window_minutes) do
      if User.valid_password?(user, password),
        do: Throttle.clear(key),
        else: {:error, :invalid_credentials}
    end
  end

  @doc """
  Change le mot de passe et révoque toutes les sessions du membre, sauf `keep_token` (session courante) si fourni,
  ainsi que les challenges 2FA en cours.
  """
  def change_password(%User{} = user, attrs, keep_token) do
    with :ok <- verify_password(user, attrs["current_password"]),
         {:ok, user} <-
           Repo.transact(fn ->
             with {:ok, user} <- user |> User.password_changeset(attrs) |> Repo.update() do
               Repo.delete_all(sessions_to_revoke(user, keep_token))
               Repo.delete_all(from c in LoginChallenge, where: c.user_id == ^user.id)
               {:ok, user}
             end
           end) do
      sessions_revoked(user.id)
      MlAccounts.Notify.security(user.id, "password_changed", %{method: "settings"})
      {:ok, user}
    end
  end

  defp sessions_to_revoke(user, nil), do: from(s in Session, where: s.user_id == ^user.id)

  defp sessions_to_revoke(user, keep_token),
    do: where(sessions_to_revoke(user, nil), [s], s.token_hash != ^hash(keep_token))

  ## Mot de passe oublié

  @doc "Envoie un lien de réinitialisation si le compte existe, sans jamais révéler s'il existe."
  def request_password_reset(email) when is_binary(email) do
    with %User{} = user <- Repo.get_by(User, email: User.normalize(email)),
         recent =
           from(t in UserToken,
             where: t.user_id == ^user.id and t.context == "reset_password",
             where: t.inserted_at > ago(1, "hour")
           ),
         true <- Repo.aggregate(recent, :count) < @reset_emails_per_hour do
      token = insert_token(user, "reset_password", user.email)
      deliver(UserEmail.password_reset(user, token), user)
    end

    :ok
  end

  def request_password_reset(_), do: :ok

  @doc "Indique si un jeton de réinitialisation est encore utilisable, sans le consommer."
  def password_reset_valid?(token), do: is_binary(token) and Repo.exists?(reset_token(token))

  defp reset_token(token) do
    from t in UserToken,
      join: u in assoc(t, :user),
      where: t.token_hash == ^hash(token) and t.context == "reset_password",
      where: t.inserted_at > ago(^@reset_minutes, "minute") and t.sent_to == u.email
  end

  @doc "Change le mot de passe par lien de réinitialisation et révoque toutes les sessions."
  def reset_password(token, attrs) when is_binary(token) do
    Repo.transact(fn ->
      case token |> reset_token() |> lock("FOR UPDATE") |> select([_t, u], u) |> Repo.one() do
        nil -> {:error, :not_found}
        user -> apply_reset(user, attrs)
      end
    end)
    |> tap(fn
      {:ok, user} ->
        sessions_revoked(user.id)
        MlAccounts.Notify.security(user.id, "password_changed", %{method: "reset"})

      _ ->
        :ok
    end)
  end

  def reset_password(_, _), do: {:error, :not_found}

  defp apply_reset(user, attrs) do
    changeset = User.password_changeset(user, attrs)

    changeset =
      if user.confirmed_at,
        do: changeset,
        else: Ecto.Changeset.change(changeset, confirmed_at: DateTime.utc_now(:second))

    with {:ok, user} <- Repo.update(changeset) do
      Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)
      Repo.delete_all(from t in ConfirmationToken, where: t.user_id == ^user.id)
      Repo.delete_all(from s in Session, where: s.user_id == ^user.id)
      Repo.delete_all(from c in LoginChallenge, where: c.user_id == ^user.id)
      Repo.delete_all(from f in LoginFailure, where: f.email == ^user.email)
      {:ok, user}
    end
  end

  ## Changement d'e-mail vérifié

  @doc "Envoie un lien de confirmation à la nouvelle adresse et prévient l'ancienne ; le mot de passe est exigé."
  def request_email_change(%User{} = user, attrs) do
    with :ok <- verify_password(user, attrs["password"]),
         {:ok, %User{email: new_email}} <-
           user |> User.email_changeset(attrs) |> Ecto.Changeset.apply_action(:validate),
         :ok <- email_change_quota(user) do
      Repo.delete_all(
        from t in UserToken, where: t.user_id == ^user.id and t.context == "change_email"
      )

      token = insert_token(user, "change_email", new_email)
      deliver(UserEmail.email_change_confirmation(user, new_email, token), user)
      deliver(UserEmail.email_change_notice(user, new_email), user)
    end
  end

  defp email_change_quota(user) do
    case Throttle.reserve("email_change:" <> user.id, @email_changes_per_hour, 60) do
      :ok -> :ok
      {:error, :locked} -> {:error, :rate_limited}
    end
  end

  @doc "Applique un changement d'adresse avec un jeton du membre lui-même, valable 24 heures et à usage unique."
  def confirm_email_change(%User{} = user, token) when is_binary(token) do
    # les e-mails de ce changement existent déjà (avis à l'ancienne adresse, lien à la nouvelle) : le centre
    # n'ajoute que l'entrée in-app
    Repo.transact(fn ->
      pending =
        from t in UserToken,
          where: t.token_hash == ^hash(token) and t.context == "change_email",
          where: t.user_id == ^user.id and t.inserted_at > ago(^@email_change_hours, "hour"),
          lock: "FOR UPDATE"

      with %UserToken{sent_to: new_email} <- Repo.one(pending) || {:error, :not_found},
           {:ok, user} <- user |> User.email_changeset(%{"email" => new_email}) |> Repo.update() do
        Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)
        {:ok, user}
      end
    end)
    |> tap(fn
      {:ok, user} -> MlAccounts.Notify.security(user.id, "email_changed")
      _ -> :ok
    end)
  end

  def confirm_email_change(_, _), do: {:error, :not_found}

  ## Profils

  def get_user(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(User, id)
      :error -> nil
    end
  end

  @doc "Membre actif de ce pseudonyme (un compte supprimé n'a plus de profil public)."
  def get_user_by_username(username) when is_binary(username),
    do: Repo.one(from u in User, where: u.username == ^username and is_nil(u.deleted_at))

  def get_user_by_username(_username), do: nil

  def update_profile(%User{} = user, attrs) do
    with {:ok, user} <- user |> User.profile_changeset(attrs) |> Repo.update() do
      profile_changed(user.id)
      {:ok, user}
    end
  end

  @doc "Met à jour les préférences ; un thème VIP est refusé si billing ne confirme pas la formule VIP."
  def update_preferences(%User{} = user, attrs) when is_map(attrs) do
    changeset = MlAccounts.Preferences.changeset(user.preferences, attrs)

    with {:ok, prefs} <- Ecto.Changeset.apply_action(changeset, :update),
         :ok <- check_theme(user, Ecto.Changeset.get_change(changeset, :theme)),
         {:ok, user} <-
           user
           |> Ecto.Changeset.change(preferences: MlAccounts.Preferences.to_map(prefs))
           |> Repo.update() do
      profile_changed(user.id)
      {:ok, user}
    end
  end

  def update_preferences(_user, _attrs), do: {:error, {:invalid, %{preferences: ["is invalid"]}}}

  defp check_theme(user, theme) do
    if theme in MlAccounts.Preferences.vip_themes() do
      case MlShared.Client.get(:billing, "/api/entitlements/:id", path_params: [id: user.id]) do
        {:ok, %{"plan" => "vip", "status" => status}} when status in ~w(active past_due) -> :ok
        {:ok, %{"plan" => _}} -> {:error, :vip_required}
        _ -> {:error, :entitlements_unavailable}
      end
    else
      :ok
    end
  end

  @doc """
  Accueil guidé : `completed` ou `skipped` (plus proposé), ou `pending` (relancé depuis les paramètres).
  """
  def set_onboarding(%User{} = user, status) when status in ~w(pending completed skipped) do
    with {:ok, user} <- user |> User.onboarding_changeset(status) |> Repo.update() do
      profile_changed(user.id)
      {:ok, user}
    end
  end

  def set_onboarding(_user, _status), do: {:error, {:invalid, %{status: ["is invalid"]}}}

  @doc "Profil, préférences ou avatar modifiés : les pages ouvertes du membre se mettent à jour."
  def profile_changed(user_id),
    do: MlShared.Events.broadcast(MlShared.Events.user(user_id), {:profile_changed, user_id})

  @doc "Membres dont l'id figure dans `ids` ; les ids inconnus ou mal formés sont ignorés."
  def list_users(ids) do
    ids = for id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], uniq: true, do: uuid
    Repo.all(from u in User, where: u.id in ^ids, order_by: u.username)
  end

  @doc "Préfixe (insensible à la casse) du pseudonyme ou du nom affiché ; comptes confirmés, hors appelant, 20 au plus."
  def search_users(query, %User{id: caller_id}) do
    prefix = String.replace(query, ["\\", "%", "_"], &"\\#{&1}") <> "%"

    Repo.all(
      from u in User,
        where: u.id != ^caller_id and not is_nil(u.confirmed_at) and is_nil(u.deleted_at),
        where: ilike(u.username, ^prefix) or ilike(u.display_name, ^prefix),
        order_by: u.username,
        limit: 20
    )
  end

  defp insert_token(user, context, sent_to) do
    {token, token_hash} = new_token()

    Repo.insert!(%UserToken{
      user_id: user.id,
      context: context,
      token_hash: token_hash,
      sent_to: sent_to
    })

    token
  end

  defp deliver(email, user) do
    with {:error, reason} <- Mailer.deliver(email) do
      Logger.error("#{email.subject}: email not delivered to user #{user.id}: #{inspect(reason)}")
    end

    :ok
  end

  defp new_token do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {token, hash(token)}
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
