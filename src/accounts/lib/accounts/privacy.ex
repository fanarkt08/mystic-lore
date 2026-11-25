defmodule MlAccounts.Privacy do
  @moduledoc """
  Export des données d'un membre et suppression de son compte, exécutée service par service après un délai de grâce.
  Une étape réussie n'est jamais rejouée et le compte est anonymisé à la fin.
  """
  import Ecto.Query
  require Logger

  alias MlAccounts.{
    ConfirmationToken,
    DataExport,
    DeletionStep,
    LoginChallenge,
    LoginFailure,
    Mailer,
    RecoveryCode,
    Repo,
    Sanction,
    SanctionAppeal,
    Session,
    SupportRequest,
    Throttle,
    TwoFactor,
    User,
    UserEmail,
    UserToken
  }

  alias MlAccounts.Privacy.{DeletionWorker, ExportWorker}
  alias MlShared.Client

  @export_services [
    :learning,
    :billing,
    :social,
    :multiplayer,
    :community,
    :studio,
    :notifications
  ]
  # notifications en dernier : les étapes précédentes ne peuvent plus lui en créer
  @deletion_services [
    :multiplayer,
    :studio,
    :community,
    :social,
    :billing,
    :learning,
    :notifications
  ]
  @exports_per_day 3
  @export_hours 24
  @deleted_name "Deleted member"

  def export_services, do: @export_services
  def deletion_services, do: @deletion_services
  def deleted_name, do: @deleted_name

  defp grace_days, do: Application.get_env(:accounts, :deletion_grace_days, 30)

  ## Export

  @doc "Crée un export de données après vérification du mot de passe, 3 par 24 heures au plus."
  def request_export(%User{} = user, password) do
    with :ok <- MlAccounts.verify_password(user, password),
         :ok <- export_quota(user) do
      {:ok, export} =
        Repo.transact(fn ->
          export = Repo.insert!(%DataExport{user_id: user.id})
          Oban.insert!(ExportWorker.new(%{export_id: export.id}))
          {:ok, export}
        end)

      changed(user.id)
      {:ok, export}
    end
  end

  defp export_quota(user) do
    case Throttle.reserve("export:" <> user.id, @exports_per_day, @export_hours * 60) do
      :ok -> :ok
      {:error, :locked} -> {:error, :rate_limited}
    end
  end

  @doc "Exports du membre, le plus récent d'abord (sans leur contenu)."
  def list_exports(%User{id: user_id}) do
    Repo.all(
      from e in DataExport,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        select:
          struct(e, [
            :id,
            :user_id,
            :status,
            :failed_services,
            :completed_at,
            :expires_at,
            :inserted_at
          ])
    )
  end

  @doc "`pending`, `ready`, `failed`, ou `expired` pour un export terminé dont le délai de 24 h est passé."
  def status(%DataExport{status: status, expires_at: expires_at}, now \\ DateTime.utc_now()) do
    if (status in ["ready", "failed"] and expires_at) && DateTime.compare(expires_at, now) != :gt,
      do: "expired",
      else: status
  end

  @doc "Document complet d'un export prêt du membre, sinon `:not_found`, `:not_ready` ou `:expired`."
  def download(%User{id: user_id}, export_id) do
    with {:ok, id} <- Ecto.UUID.cast(export_id),
         %DataExport{} = export <- Repo.get_by(DataExport, id: id, user_id: user_id) do
      case status(export) do
        "ready" -> {:ok, document(export)}
        "expired" -> {:error, :expired}
        _ -> {:error, :not_ready}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp document(export) do
    %{
      "format" => "mysticlore-export/1",
      "user_id" => export.user_id,
      "requested_at" => export.inserted_at,
      "generated_at" => export.completed_at,
      "expires_at" => export.expires_at,
      "services" => export.data
    }
  end

  @doc "Assemble un export en attente en ne redemandant que les sections manquantes."
  def build_export(export_id, last_attempt?) do
    case Repo.get(DataExport, export_id) do
      %DataExport{status: "pending"} = export -> assemble(export, last_attempt?)
      # déjà terminé, ou supprimé avec le compte entre-temps
      _ -> :ok
    end
  end

  defp assemble(export, last_attempt?) do
    user = Repo.get!(User, export.user_id)
    data = Map.put(export.data || %{}, "accounts", accounts_section(user))

    {data, failed} =
      Enum.reduce(@export_services, {data, []}, fn service, {data, failed} ->
        key = Atom.to_string(service)

        cond do
          Map.has_key?(data, key) ->
            {data, failed}

          section = fetch_section(service, user.id) ->
            {Map.put(data, key, section), failed}

          true ->
            {data, failed ++ [key]}
        end
      end)

    now = DateTime.utc_now(:second)
    expires_at = DateTime.add(now, @export_hours * 3600)

    cond do
      failed == [] ->
        finish(export,
          status: "ready",
          data: data,
          failed_services: [],
          completed_at: now,
          expires_at: expires_at
        )

      last_attempt? ->
        Logger.warning(
          "data export #{export.id}: unavailable services #{Enum.join(failed, ", ")}"
        )

        finish(export,
          status: "failed",
          data: nil,
          failed_services: failed,
          completed_at: now,
          expires_at: expires_at
        )

      true ->
        # sections déjà obtenues gardées : la relance ne redemande que les services manquants
        finish(export, data: data, failed_services: failed)
        {:error, {:unavailable, failed}}
    end
  end

  # 30 s : la section de social contient les pièces jointes du membre (Base64)
  defp fetch_section(service, user_id) do
    case Client.get(service, "/api/internal/users/#{user_id}/export", receive_timeout: 30_000) do
      {:ok, %{"data" => section}} when is_map(section) -> section
      _ -> nil
    end
  end

  # Mise à jour conditionnelle : sans effet si l'export a été supprimé (compte anonymisé) pendant l'assemblage.
  defp finish(export, changes) do
    changes = Keyword.put(changes, :updated_at, DateTime.utc_now(:second))

    {updated, _} =
      Repo.update_all(from(e in DataExport, where: e.id == ^export.id and e.status == "pending"),
        set: changes
      )

    changed(export.user_id)

    case changes[:status] do
      status when status in ["ready", "failed"] and updated == 1 ->
        MlAccounts.Notify.account(
          export.user_id,
          "export_#{status}",
          %{export_id: export.id},
          "export:#{export.id}:#{status}"
        )

      _pending ->
        :ok
    end

    :ok
  end

  defp accounts_section(%User{} = user) do
    sessions =
      Repo.all(from s in Session, where: s.user_id == ^user.id, order_by: [desc: s.last_used_at])

    %{
      "profile" => %{
        "id" => user.id,
        "email" => user.email,
        "username" => user.username,
        "display_name" => user.display_name,
        "bio" => user.bio,
        "pronouns" => user.pronouns,
        "interests" => user.interests,
        "cover" => user.cover,
        "profile_visibility" => user.profile_visibility,
        "avatar" => MlAccounts.Avatars.export(user),
        "role" => user.role,
        "confirmed_at" => user.confirmed_at,
        "inserted_at" => user.inserted_at,
        "updated_at" => user.updated_at
      },
      "preferences" => MlAccounts.Preferences.to_map(user.preferences),
      "two_factor" => TwoFactor.status(user),
      "sessions" =>
        for s <- sessions do
          %{
            "user_agent" => s.user_agent,
            "ip" => s.ip,
            "inserted_at" => s.inserted_at,
            "last_used_at" => s.last_used_at
          }
        end,
      "deletion_scheduled_at" => user.deletion_scheduled_at,
      # sanctions reçues et appels (sans l'identité du membre du staff)
      "sanctions" =>
        for s <- MlAccounts.Sanctions.for_user(user.id) do
          %{
            "kind" => s.kind,
            "reason" => s.reason,
            "status" => Sanction.status(s),
            "ends_at" => s.ends_at,
            "inserted_at" => s.inserted_at,
            "lifted_at" => s.lifted_at,
            "appeals" =>
              Enum.map(
                s.appeals,
                &Map.take(&1, [:body, :status, :decision_reason, :decided_at, :inserted_at])
              )
          }
        end,
      # accueil guidé et demandes de support, avec les réponses et la note interne (sans l'identité du staff)
      "onboarding" => %{"status" => user.onboarding_status, "at" => user.onboarding_at},
      "support_requests" => MlAccounts.Support.export(user)
    }
  end

  @doc "Supprime les exports expirés, et ceux restés en attente plus de 24 h (tâche perdue) : balayage."
  def purge_expired_exports(now \\ DateTime.utc_now()) do
    stuck = DateTime.add(now, -@export_hours * 3600)

    {count, _} =
      Repo.delete_all(
        from e in DataExport,
          where: e.expires_at <= ^now or (e.status == "pending" and e.inserted_at <= ^stuck)
      )

    count
  end

  defp changed(user_id),
    do: MlShared.Events.broadcast(MlShared.Events.user(user_id), {:data_export_changed, user_id})

  ## Suppression du compte

  @doc "Programme la suppression du compte après le délai de grâce et révoque toutes les sessions."
  def schedule_deletion(%User{} = user, params) do
    with :ok <- MlAccounts.verify_password(user, params["password"]),
         :ok <- confirm_username(user, params["confirm_username"]),
         :ok <- not_last_admin(user) do
      now = DateTime.utc_now(:second)
      at = DateTime.add(now, grace_days() * 86_400)

      pending =
        from u in User,
          where: u.id == ^user.id and is_nil(u.deletion_scheduled_at) and is_nil(u.deleted_at),
          select: u

      case Repo.update_all(pending, set: [deletion_scheduled_at: at, updated_at: now]) do
        {1, [user]} ->
          revoke_access(user)
          deliver(UserEmail.deletion_scheduled(user, at), user)
          {:ok, user}

        {0, _} ->
          {:ok, Repo.get!(User, user.id)}
      end
    end
  end

  # La suppression d'un admin ne doit jamais laisser la plateforme sans administrateur actif
  # (admin sans suppression programmée ni effectuée).
  defp not_last_admin(%User{role: "admin", id: id}) do
    others =
      Repo.aggregate(
        from(u in User,
          where:
            u.role == "admin" and u.id != ^id and is_nil(u.deletion_scheduled_at) and
              is_nil(u.deleted_at)
        ),
        :count
      )

    if others > 0, do: :ok, else: {:error, :last_admin}
  end

  defp not_last_admin(_user), do: :ok

  defp confirm_username(user, value) when is_binary(value) do
    if User.normalize(value) == user.username,
      do: :ok,
      else: {:error, {:invalid, %{confirm_username: ["does not match your username"]}}}
  end

  defp confirm_username(_user, _value),
    do: {:error, {:invalid, %{confirm_username: ["can't be blank"]}}}

  @doc "Annule une suppression avant son échéance (`:not_found` si rien n'est programmé)."
  def cancel_deletion(%User{id: id}) do
    now = DateTime.utc_now(:second)

    scheduled =
      from u in User,
        where: u.id == ^id and u.deletion_scheduled_at > ^now and is_nil(u.deleted_at),
        select: u

    case Repo.update_all(scheduled, set: [deletion_scheduled_at: nil, updated_at: now]) do
      {1, [user]} ->
        {:ok, user}

      {0, _} ->
        if Repo.get!(User, id).deletion_scheduled_at,
          do: {:error, :deletion_in_progress},
          else: {:error, :not_found}
    end
  end

  @doc "Échéance passée (suppression en cours) ou compte déjà anonymisé : plus de connexion ni d'action."
  def deleting?(%User{deleted_at: %DateTime{}}), do: true

  def deleting?(%User{deletion_scheduled_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  def deleting?(_user), do: false

  @doc "Met en file une tâche (unique par membre) pour chaque suppression due ; renvoie le nombre de membres."
  def enqueue_due_deletions(now \\ DateTime.utc_now()) do
    ids =
      Repo.all(
        from u in User,
          where: u.deletion_scheduled_at <= ^now and is_nil(u.deleted_at),
          select: u.id
      )

    Enum.each(ids, &Oban.insert!(DeletionWorker.new(%{user_id: &1})))
    length(ids)
  end

  @doc "Exécute une suppression due service par service, puis anonymise le compte."
  def execute_deletion(user_id) do
    case Repo.get(User, user_id) do
      %User{deleted_at: nil} = user -> if deleting?(user), do: run_steps(user), else: :ok
      _ -> :ok
    end
  end

  defp run_steps(user) do
    revoke_access(user)
    done = Repo.all(from s in DeletionStep, where: s.user_id == ^user.id, select: s.service)

    @deletion_services
    |> Enum.reject(&(Atom.to_string(&1) in done))
    |> Enum.reduce_while(:ok, fn service, :ok ->
      case Client.delete(service, "/api/internal/users/#{user.id}") do
        {:ok, _} ->
          record_step(user.id, Atom.to_string(service))
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("account deletion #{user.id}: #{service} failed (#{failure(reason)})")
          {:halt, {:error, {service, failure(reason)}}}
      end
    end)
    |> case do
      :ok -> anonymize(user)
      error -> error
    end
  end

  defp failure({:http, status, _body}), do: "HTTP #{status}"
  defp failure(reason), do: to_string(reason)

  defp record_step(user_id, service),
    do: Repo.insert!(%DeletionStep{user_id: user_id, service: service}, on_conflict: :nothing)

  # Sessions et challenges 2FA supprimés ; publié seulement si une session a été coupée.
  defp revoke_access(user) do
    Repo.delete_all(from c in LoginChallenge, where: c.user_id == ^user.id)

    case Repo.delete_all(from s in Session, where: s.user_id == ^user.id) do
      {0, _} -> :ok
      _ -> sessions_revoked(user.id)
    end
  end

  # Dernière étape : l'identifiant reste pour les contributions conservées ailleurs, tout le reste disparaît.
  defp anonymize(user) do
    unusable = Bcrypt.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32)))

    keys =
      for kind <- ~w(password totp email_change export support_account), do: "#{kind}:#{user.id}"

    {:ok, avatar_image} =
      Repo.transact(fn ->
        user = Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")

        # demandes de support du membre (leurs réponses suivent, ON DELETE CASCADE)
        for schema <- [
              SupportRequest,
              SanctionAppeal,
              Sanction,
              Session,
              LoginChallenge,
              RecoveryCode,
              UserToken,
              ConfirmationToken,
              DataExport
            ],
            do: Repo.delete_all(from x in schema, where: x.user_id == ^user.id)

        Repo.delete_all(from t in Throttle, where: t.key in ^keys)
        Repo.delete_all(from f in LoginFailure, where: f.email == ^user.email)

        user
        |> Ecto.Changeset.change(
          email: "deleted-#{user.id}@deleted.invalid",
          username: "deleted_" <> (user.id |> String.replace("-", "") |> String.slice(-16, 16)),
          display_name: @deleted_name,
          bio: nil,
          pronouns: nil,
          interests: [],
          cover: nil,
          profile_visibility: "members",
          avatar_crest: nil,
          avatar_image: nil,
          preferences: MlAccounts.Preferences.to_map(%MlAccounts.Preferences{}),
          hashed_password: unusable,
          role: "user",
          totp_secret: nil,
          totp_pending_secret: nil,
          totp_last_step: nil,
          totp_enabled_at: nil,
          deleted_at: DateTime.utc_now(:second)
        )
        |> Repo.update!()

        record_step(user.id, "accounts")
        {:ok, user.avatar_image}
      end)

    # le fichier de l'avatar disparaît avec le compte (après l'écriture en base)
    MlAccounts.Avatars.delete_file(avatar_image)
    sessions_revoked(user.id)
    :ok
  end

  defp sessions_revoked(user_id) do
    MlShared.Events.broadcast(MlShared.Events.user(user_id), {:sessions_revoked, user_id})
    :ok
  end

  defp deliver(email, user) do
    with {:error, reason} <- Mailer.deliver(email) do
      Logger.error("#{email.subject}: email not delivered to user #{user.id}: #{inspect(reason)}")
    end

    :ok
  end
end
