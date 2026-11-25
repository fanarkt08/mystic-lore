defmodule MlNotifications.Emails do
  @moduledoc """
  Canal e-mail. Le centre ne stocke jamais d'adresse : il demande l'envoi à accounts.
  """
  import Ecto.Query
  alias MlNotifications.{Catalog, DigestWorker, EmailLog, EmailWorker}
  alias MlNotifications.{Notification, PendingEmail, Preferences, QuietHours, Repo, Setting}

  @digest_states [:available, :scheduled, :retryable]

  defp config(key), do: Application.fetch_env!(:notifications, key)

  @doc "Planifie l'e-mail d'une notification créée ou agrégée (dans la transaction de la création)."
  def plan(input, %Setting{} = setting, notification, now) do
    spec = Catalog.kind(input.kind)
    mandatory = Catalog.mandatory?(input.kind)

    cond do
      spec.email != :center ->
        "none"

      not Preferences.enabled?(setting, input.category, "email", input.kind) ->
        "none"

      input.category == "security" ->
        enqueue(input, notification, true, 0, now)

      QuietHours.active?(setting, now) ->
        defer(input, setting, notification, mandatory, now)

      not mandatory and limited?(input.user_id, input.dedupe_key, now) ->
        "none"

      true ->
        delay = if mandatory, do: 0, else: config(:email_delay_seconds)
        enqueue(input, notification, mandatory, delay, now)
    end
  end

  defp enqueue(input, notification, mandatory, delay, now) do
    log = log!(input.user_id, input.dedupe_key, input.category, input.kind, now)

    %{
      user_id: input.user_id,
      category: input.category,
      kind: input.kind,
      actor_id: input.actor_id,
      params: input.params,
      notification_id: notification && notification.id,
      mandatory: mandatory,
      log_id: log.id
    }
    |> EmailWorker.new(schedule_in: delay)
    |> Oban.insert!()

    "queued"
  end

  defp log!(user_id, key, category, kind, now) do
    Repo.insert!(%EmailLog{
      user_id: user_id,
      dedupe_key: key,
      category: category,
      kind: kind,
      inserted_at: now
    })
  end

  @doc "Limite de débit : un e-mail par clé et par heure, plafond quotidien par membre (hors sécurité)."
  def limited?(user_id, key, now) do
    window = DateTime.add(now, -config(:email_key_window_seconds), :second)
    day = DateTime.add(now, -86_400, :second)

    Repo.exists?(
      from l in EmailLog,
        where: l.user_id == ^user_id and l.dedupe_key == ^key and l.inserted_at > ^window
    ) or
      Repo.aggregate(
        from(l in EmailLog,
          where: l.user_id == ^user_id and l.category != "security" and l.inserted_at > ^day
        ),
        :count
      ) >= config(:email_daily_cap)
  end

  defp defer(input, setting, notification, mandatory, now) do
    Repo.insert!(%PendingEmail{
      user_id: input.user_id,
      notification_id: notification && notification.id,
      category: input.category,
      kind: input.kind,
      actor_id: input.actor_id,
      params: input.params,
      dedupe_key: input.dedupe_key,
      mandatory: mandatory,
      inserted_at: now
    })

    schedule_digest(input.user_id, QuietHours.ends_at(setting, now))
    "deferred"
  end

  # un seul résumé en attente par membre : une nouvelle planification remplace sa date
  defp schedule_digest(user_id, at) do
    %{user_id: user_id}
    |> DigestWorker.new(
      scheduled_at: at,
      unique: [period: :infinity, keys: [:user_id], states: @digest_states],
      replace: [scheduled: [:scheduled_at]]
    )
    |> Oban.insert!()
  end

  @doc "Après un changement des heures calmes : le résumé en attente part à leur nouvelle fin, ou tout de suite."
  def reschedule_digest(%Setting{user_id: user_id} = setting, now) do
    if Repo.exists?(from p in PendingEmail, where: p.user_id == ^user_id),
      do: schedule_digest(user_id, QuietHours.ends_at(setting, now) || now)

    :ok
  end

  @doc "Date prévue du résumé en attente (`nil` s'il n'y en a pas)."
  def digest_at(user_id) do
    Repo.one(
      from j in Oban.Job,
        where: j.worker == "MlNotifications.DigestWorker",
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("?->>'user_id' = ?", j.args, ^user_id),
        select: j.scheduled_at,
        limit: 1
    )
  end

  @doc "Construit le contenu du résumé, un élément par clé, sans les notifications déjà lues."
  def digest_items(user_id) do
    rows =
      Repo.all(
        from p in PendingEmail,
          where: p.user_id == ^user_id,
          order_by: [asc: p.inserted_at, asc: p.id]
      )

    read =
      rows
      |> Enum.map(& &1.notification_id)
      |> Enum.reject(&is_nil/1)
      |> then(
        &Repo.all(
          from n in Notification, where: n.id in ^&1 and not is_nil(n.read_at), select: n.id
        )
      )
      |> MapSet.new()

    items =
      rows
      |> Enum.reject(&(not &1.mandatory and MapSet.member?(read, &1.notification_id)))
      |> Enum.group_by(& &1.dedupe_key)
      |> Enum.map(fn {_key, group} ->
        last = List.last(group)

        {last.inserted_at,
         %{kind: last.kind, params: last.params, actor_id: last.actor_id, count: length(group)}}
      end)
      |> Enum.sort_by(&elem(&1, 0), DateTime)
      |> Enum.map(&elem(&1, 1))

    {rows, items}
  end

  @doc "Marque un e-mail confirmé par accounts."
  def sent!(log_id, now \\ DateTime.utc_now()) when is_integer(log_id),
    do: Repo.update_all(from(l in EmailLog, where: l.id == ^log_id), set: [sent_at: now])

  def log_digest!(user_id, now), do: log!(user_id, "digest", "digest", "digest", now)

  @doc "Demande l'envoi à accounts : `:ok`, `{:discard, raison}` (définitif) ou `{:retry, raison}`."
  def request(user_id, body) do
    case MlShared.Client.post(:accounts, "/api/internal/users/#{user_id}/notification-email",
           json: body
         ) do
      {:ok, %{"status" => "sent"}} -> :ok
      {:ok, _other} -> {:retry, :unexpected_response}
      {:error, {:http, status, body}} when status in [404, 409, 422] -> {:discard, code(body)}
      {:error, {:http, status, _body}} -> {:retry, {:http, status}}
      {:error, :unavailable} -> {:retry, :unavailable}
    end
  end

  defp code(%{"error" => code}) when is_binary(code), do: code
  defp code(_body), do: "refused"
end
