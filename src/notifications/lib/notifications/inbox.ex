defmodule MlNotifications.Inbox do
  @moduledoc """
  Notifications d'un membre : création agrégée par clé, lecture, liste par curseur et rétention.
  """
  import Ecto.Query
  alias MlNotifications.{Catalog, Emails, Notification, PendingEmail, Preferences, QuietHours}
  alias MlNotifications.{Repo, Setting}
  alias MlShared.Events

  @page_size 20
  @max_page 50

  ## Création

  @doc """
  `{:ok, %{status, notification, email}}` (`status` : `created`, `aggregated`, `duplicate` ou `skipped`),
  `{:error, :forbidden}` ou `{:error, {:invalid, erreurs}}`.
  """
  def create(caller, attrs, now \\ DateTime.utc_now()) do
    now = usec(now)

    with {:ok, input} <- Catalog.validate(caller, attrs) do
      # date de l'événement chez le producteur, jamais dans le futur ; absente → maintenant
      occurred_at = usec(input.occurred_at || now)

      input = %{
        input
        | occurred_at: if(DateTime.after?(occurred_at, now), do: now, else: occurred_at)
      }

      {:ok, result} = Repo.transact(fn -> {:ok, create_locked(input, now)} end)

      if result.status in ["created", "aggregated"],
        do: changed(input.user_id, toast(result, input, now))

      {:ok, result}
    end
  end

  defp create_locked(input, now) do
    serialize(input.user_id, input.dedupe_key)

    cond do
      not new_event?(input, now) ->
        %{status: "duplicate", notification: nil, email: "none", setting: nil}

      read_after?(input) ->
        %{status: "skipped", notification: nil, email: "none", setting: nil}

      true ->
        setting = Preferences.get(input.user_id)

        {status, notification} =
          if Preferences.enabled?(setting, input.category, "in_app", input.kind),
            do: upsert(input, now),
            else: {"skipped", nil}

        email = Emails.plan(input, setting, notification, now)
        %{status: status, notification: notification, email: email, setting: setting}
    end
  end

  defp serialize(user_id, key),
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["#{user_id}:#{key}"])

  defp new_event?(input, now) do
    {count, _} =
      Repo.insert_all(
        "notification_events",
        [%{user_id: dump(input.user_id), event_id: input.event_id, inserted_at: now}],
        on_conflict: :nothing
      )

    count == 1
  end

  defp read_after?(input) do
    Repo.exists?(
      from m in "notification_read_marks",
        where:
          m.user_id == type(^input.user_id, :binary_id) and m.dedupe_key == ^input.dedupe_key,
        where: m.read_at >= ^input.occurred_at
    )
  end

  # Une seule notification non lue par clé : l'insertion agrège en cas de conflit.
  defp upsert(input, now) do
    row = %Notification{
      user_id: input.user_id,
      category: input.category,
      kind: input.kind,
      actor_id: input.actor_id,
      subject_type: input.subject_type,
      subject_id: input.subject_id,
      params: input.params,
      dedupe_key: input.dedupe_key,
      count: 1,
      last_event_at: input.occurred_at,
      inserted_at: now,
      updated_at: now
    }

    aggregate =
      from n in Notification,
        update: [
          inc: [count: 1],
          set: [
            actor_id: type(^input.actor_id, :binary_id),
            params: type(^input.params, :map),
            subject_id: type(^input.subject_id, :string),
            last_event_at: fragment("GREATEST(?, EXCLUDED.last_event_at)", n.last_event_at),
            updated_at: ^now
          ]
        ]

    notification =
      Repo.insert!(row,
        on_conflict: aggregate,
        conflict_target: {:unsafe_fragment, "(user_id, dedupe_key) WHERE read_at IS NULL"},
        returning: true
      )

    if notification.count == 1 do
      cap(input.user_id)
      {"created", notification}
    else
      {"aggregated", notification}
    end
  end

  # au plus `max_per_member` notifications : les plus anciennes (dernier événement) partent
  defp cap(user_id) do
    max = Application.fetch_env!(:notifications, :max_per_member)

    beyond =
      from n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.last_event_at, desc: n.id],
        offset: ^max,
        select: n.id

    Repo.delete_all(from n in Notification, where: n.id in subquery(beyond))
  end

  defp toast(%{notification: %Notification{read_at: nil} = n, setting: setting}, input, now) do
    if input.category == "security" or not QuietHours.active?(setting, now),
      do: %{"id" => n.id, "category" => n.category}
  end

  defp toast(_result, _input, _now), do: nil

  ## Lecture (membre)

  @doc "Renvoie une page de notifications de `user_id`, de la plus récente à la plus ancienne."
  def list(user_id, params) do
    limit = limit(params["limit"])

    with {:ok, cursor} <- cursor(params["before"]) do
      entries =
        from(n in Notification,
          where: n.user_id == ^user_id,
          order_by: [desc: n.last_event_at, desc: n.id],
          limit: ^(limit + 1)
        )
        |> unread_only(params["filter"])
        |> older_than(cursor)
        |> Repo.all()

      {page, rest} = Enum.split(entries, limit)
      next = if rest != [], do: encode_cursor(List.last(page))
      {:ok, %{entries: page, next_before: next}}
    end
  end

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> min(n, @max_page)
      _ -> @page_size
    end
  end

  defp unread_only(query, "unread"), do: where(query, [n], is_nil(n.read_at))
  defp unread_only(query, _all), do: query

  defp older_than(query, nil), do: query

  defp older_than(query, {at, id}),
    do: where(query, [n], n.last_event_at < ^at or (n.last_event_at == ^at and n.id < ^id))

  defp encode_cursor(%Notification{last_event_at: at, id: id}),
    do: Base.url_encode64("#{DateTime.to_unix(at, :microsecond)}~#{id}", padding: false)

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(value) when is_binary(value) do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         [micro, id] <- String.split(raw, "~", parts: 2),
         {micro, ""} <- Integer.parse(micro),
         {:ok, at} <- DateTime.from_unix(micro, :microsecond),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> {:error, {:invalid, %{before: ["is invalid"]}}}
    end
  end

  defp cursor(_value), do: {:error, {:invalid, %{before: ["is invalid"]}}}

  def unread_count(user_id),
    do:
      Repo.aggregate(
        from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at)),
        :count
      )

  @doc "Une notification de `user_id` (`{:error, :not_found}` sinon : rien n'est révélé)."
  def get(user_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Notification{} = n <- Repo.get_by(Notification, id: id, user_id: user_id) do
      {:ok, n}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Marque lue une notification de `user_id` (idempotent)."
  def read(user_id, id, now \\ DateTime.utc_now()) do
    now = usec(now)

    with {:ok, n} <- get(user_id, id) do
      if n.read_at do
        {:ok, n}
      else
        {1, [n]} =
          Repo.update_all(
            from(x in Notification, where: x.id == ^n.id, select: x),
            set: [read_at: now, updated_at: now]
          )

        changed(user_id, nil)
        {:ok, n}
      end
    end
  end

  @doc "Marque lues toutes les notifications de `user_id` et renvoie le nombre marqué."
  def read_all(user_id, now \\ DateTime.utc_now()) do
    now = usec(now)

    {count, _} =
      Repo.update_all(
        from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at)),
        set: [read_at: now, updated_at: now]
      )

    if count > 0, do: changed(user_id, nil)
    count
  end

  ## Routes internes des producteurs

  @doc "Marque lue la notification de `dedupe_key` et mémorise la lecture pour ignorer une création plus ancienne."
  def read_by_key(caller, attrs, now \\ DateTime.utc_now()) do
    now = usec(now)

    with {:ok, user_id} <- uuid(attrs["user_id"], :user_id),
         {:ok, key} <- key(attrs["dedupe_key"]),
         {:ok, read_at} <- read_at(attrs["read_at"], now),
         [_ | _] = categories <- Catalog.categories_of(caller) do
      {:ok, count} =
        Repo.transact(fn ->
          serialize(user_id, key)

          Repo.insert_all(
            "notification_read_marks",
            [%{user_id: dump(user_id), dedupe_key: key, read_at: read_at}],
            on_conflict:
              from(m in "notification_read_marks",
                update: [set: [read_at: fragment("GREATEST(?, EXCLUDED.read_at)", m.read_at)]]
              ),
            conflict_target: [:user_id, :dedupe_key]
          )

          {count, _} =
            Repo.update_all(
              from(n in Notification,
                where: n.user_id == ^user_id and n.dedupe_key == ^key and is_nil(n.read_at),
                where: n.category in ^categories and n.last_event_at <= ^read_at
              ),
              set: [read_at: now, updated_at: now]
            )

          {:ok, count}
        end)

      if count > 0, do: changed(user_id, nil)
      {:ok, count}
    else
      [] -> {:error, :forbidden}
      error -> error
    end
  end

  @doc "Efface les notifications échangées entre `a` et `b` (deux sens) et leurs e-mails reportés (blocage)."
  def clear_between(attrs) do
    with {:ok, a} <- uuid(attrs["a"], :a),
         {:ok, b} <- uuid(attrs["b"], :b) do
      between = fn query ->
        where(
          query,
          [x],
          (x.user_id == ^a and x.actor_id == ^b) or (x.user_id == ^b and x.actor_id == ^a)
        )
      end

      {:ok, count} =
        Repo.transact(fn ->
          Repo.delete_all(between.(PendingEmail))
          {count, _} = Repo.delete_all(between.(Notification))
          {:ok, count}
        end)

      if count > 0, do: Enum.each([a, b], &changed(&1, nil))
      {:ok, count}
    end
  end

  ## Rétention

  @doc "Purge (voir `MlNotifications.PurgeWorker`)."
  def purge(now) do
    days = Application.fetch_env!(:notifications, :retention_days)
    max = Application.fetch_env!(:notifications, :max_per_member)
    old = DateTime.add(now, -days * 86_400, :second)

    {expired, _} = Repo.delete_all(from n in Notification, where: n.last_event_at < ^old)

    # membres au-delà du plafond : leurs notifications classées après la 500e partent
    ranked =
      from n in Notification,
        select: %{
          id: n.id,
          rank:
            over(row_number(),
              partition_by: n.user_id,
              order_by: [desc: n.last_event_at, desc: n.id]
            )
        }

    {capped, _} =
      Repo.delete_all(
        from n in Notification,
          join: r in subquery(ranked),
          on: r.id == n.id,
          where: r.rank > ^max
      )

    Repo.delete_all(
      from e in "notification_events", where: e.inserted_at < ^DateTime.add(now, -30, :day)
    )

    Repo.delete_all(
      from m in "notification_read_marks", where: m.read_at < ^DateTime.add(now, -7, :day)
    )

    Repo.delete_all(
      from l in MlNotifications.EmailLog, where: l.inserted_at < ^DateTime.add(now, -2, :day)
    )

    Repo.delete_all(from p in PendingEmail, where: p.inserted_at < ^DateTime.add(now, -7, :day))

    %{expired: expired, capped: capped}
  end

  ## Outils

  @doc "Publie le changement de la liste de `user_id` (toutes ses pages ouvertes)."
  def changed(user_id, toast),
    do: Events.broadcast(Events.user(user_id), {:notifications_changed, user_id, toast})

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  # colonnes `utc_datetime_usec` : précision à la microseconde
  defp usec(%DateTime{} = dt), do: DateTime.add(dt, 0, :microsecond)

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid, %{field => ["is invalid"]}}}
    end
  end

  defp key(value) when is_binary(value) and byte_size(value) in 1..200, do: {:ok, value}
  defp key(_value), do: {:error, {:invalid, %{dedupe_key: ["is invalid"]}}}

  defp read_at(nil, now), do: {:ok, now}

  defp read_at(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, if(DateTime.after?(dt, now), do: now, else: usec(dt))}
      _ -> {:error, {:invalid, %{read_at: ["is invalid"]}}}
    end
  end

  defp read_at(_value, _now), do: {:error, {:invalid, %{read_at: ["is invalid"]}}}

  @doc false
  def setting(user_id), do: Repo.get(Setting, user_id)
end
