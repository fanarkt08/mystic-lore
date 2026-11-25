defmodule MlSocial.Chat do
  @moduledoc """
  Conversations, messages, lectures, sourdine et non-lus. Toute fonction exige que `me` soit membre actuel de la
  conversation, sinon `{:error, :not_found}` : l'existence d'une conversation n'est jamais révélée.
  """
  import Ecto.Query
  alias MlShared.Events

  alias MlSocial.{
    Attachments,
    Conversation,
    Delivery,
    Friends,
    Member,
    Message,
    RateLimit,
    Repo,
    Settings
  }

  @page_size 30
  @mutes %{"1h" => 3600, "8h" => 8 * 3600, "24h" => 24 * 3600}

  ## Conversations

  @doc "Liste les conversations de `me`, la plus récemment active d'abord."
  def list(me) do
    blocked = Friends.blocked_either_ids(me)
    summaries = Repo.all(summaries(me, blocked))
    with_details(summaries, blocked)
  end

  @doc "Une conversation de `me`, avec ses membres et les accusés de lecture qu'il peut voir (`reads`)."
  def get(me, conversation_id) do
    with {:ok, id} <- Ecto.UUID.cast(conversation_id),
         blocked = Friends.blocked_either_ids(me),
         %{} = summary <- Repo.one(where(summaries(me, blocked), [c: c], c.id == ^id)) do
      [summary] = with_details([summary], blocked)
      {:ok, Map.put(summary, :reads, reads(me, summary))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Ouvre (ou retrouve) la conversation directe avec `user_id` : idempotent, sûr en concurrence, entre amis."
  def open(me, user_id) do
    with {:ok, other} <- cast_user(user_id),
         {:ok, id} <- Friends.with_pair_lock(me, other, fn -> open_locked(me, other) end) do
      get(me, id)
    end
  end

  defp open_locked(me, other) do
    cond do
      Friends.blocked?(me, other) ->
        {:error, :blocked}

      not Friends.friends?(me, other) ->
        {:error, :not_friends}

      true ->
        [low, high] = Enum.sort([me, other])

        case Repo.get_by(Conversation, user_low: low, user_high: high) do
          %Conversation{id: id} ->
            {:ok, id}

          nil ->
            conversation = Repo.insert!(%Conversation{user_low: low, user_high: high})

            members =
              for user <- [low, high], do: %{conversation_id: conversation.id, user_id: user}

            Repo.insert_all(Member, members)
            {:ok, conversation.id}
        end
    end
  end

  # Une requête : dernier message par jointure latérale, non-lus (texte des autres, ni retiré ni masqué) par
  # sous-requête corrélée ; dans un groupe, seulement depuis l'arrivée de `me`.
  defp summaries(me, blocked) do
    last =
      from x in Message,
        where: x.conversation_id == parent_as(:c).id,
        where: parent_as(:c).kind != "group" or x.inserted_at >= parent_as(:m).joined_at,
        order_by: [desc: x.inserted_at, desc: x.id],
        limit: 1

    unread =
      from x in Message,
        where: x.conversation_id == parent_as(:c).id and x.sender_id != ^me,
        where: parent_as(:c).kind != "group" or x.inserted_at >= parent_as(:m).joined_at,
        where: x.kind == "text" and is_nil(x.removed_at) and x.sender_id not in ^blocked,
        where: is_nil(parent_as(:m).last_read_at) or x.inserted_at > parent_as(:m).last_read_at,
        select: count()

    from m in Member,
      as: :m,
      join: c in Conversation,
      as: :c,
      on: c.id == m.conversation_id,
      left_lateral_join: l in subquery(last),
      on: true,
      where: m.user_id == ^me,
      order_by: [desc_nulls_last: l.inserted_at, desc: c.inserted_at, desc: c.id],
      select: %{conversation: c, member: m, last_message: l, unread: subquery(unread)}
  end

  # Membres (par ancienneté) et pièce jointe du dernier message, en deux requêtes pour toute la liste.
  defp with_details(summaries, blocked) do
    ids = Enum.map(summaries, & &1.conversation.id)

    members =
      Repo.all(
        from m in Member,
          where: m.conversation_id in ^ids,
          order_by: [m.joined_at, m.user_id]
      )
      |> Enum.group_by(& &1.conversation_id)

    lasts =
      summaries
      |> Enum.map(& &1.last_message)
      |> Enum.reject(&is_nil/1)
      |> Repo.preload(:attachment)

    lasts = Map.new(lasts, &{&1.id, &1})
    hidden = MapSet.new(blocked)

    for s <- summaries do
      %{
        s
        | last_message: s.last_message && lasts[s.last_message.id]
      }
      |> Map.merge(%{members: Map.get(members, s.conversation.id, []), hidden: hidden})
    end
  end

  # Accusés de lecture visibles par `me` : seulement s'il partage les siens (réciprocité), ceux des membres qui
  # partagent les leurs et n'ont pas de blocage avec lui.
  defp reads(me, %{members: members, hidden: hidden}) do
    settings = Settings.for_users(Enum.map(members, & &1.user_id))

    if settings[me].read_receipts do
      reads =
        for m <- members,
            m.user_id != me,
            m.last_read_at,
            settings[m.user_id].read_receipts,
            not MapSet.member?(hidden, m.user_id),
            do: %{user_id: m.user_id, read_at: m.last_read_at}

      %{enabled: true, reads: reads}
    else
      %{enabled: false, reads: []}
    end
  end

  ## Messages

  @doc """
  Jusqu'à 30 messages en ordre chronologique, antérieurs au message `before` s'il est donné :
  `%{entries, next_before, hidden}` (`hidden` : expéditeurs dont les messages sont masqués pour `me`).
  """
  def messages(me, conversation_id, before) do
    with {:ok, conversation} <- membership(me, conversation_id),
         {:ok, cursor} <- cursor(conversation.id, before) do
      {entries, older} =
        from(m in Message,
          where: m.conversation_id == ^conversation.id,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^(@page_size + 1)
        )
        |> older_than(cursor)
        |> since_arrival(me, conversation)
        |> Repo.all()
        |> Enum.split(@page_size)

      next_before = if older != [], do: List.last(entries).id

      {:ok,
       %{
         entries: entries |> Enum.reverse() |> Repo.preload(:attachment),
         next_before: next_before,
         hidden: hidden_senders(me, conversation)
       }}
    end
  end

  @doc "Expéditeurs dont les messages sont masqués pour `me` dans cette conversation (groupes seulement)."
  def hidden_senders(me, %Conversation{} = conversation) do
    if Conversation.group?(conversation),
      do: MapSet.new(Friends.blocked_either_ids(me)),
      else: MapSet.new()
  end

  defp cursor(_conversation_id, before) when before in [nil, ""], do: {:ok, nil}

  defp cursor(conversation_id, before) do
    with {:ok, id} <- Ecto.UUID.cast(before),
         %Message{} = message <- Repo.get_by(Message, id: id, conversation_id: conversation_id) do
      {:ok, message}
    else
      _ -> {:error, {:invalid, %{before: ["is invalid"]}}}
    end
  end

  defp older_than(query, nil), do: query

  defp older_than(query, %Message{inserted_at: at, id: id}),
    do: where(query, [m], m.inserted_at < ^at or (m.inserted_at == ^at and m.id < ^id))

  # Groupe : rien de ce qui précède l'arrivée de `me` (voir le moduledoc).
  defp since_arrival(query, me, %Conversation{kind: "group"}) do
    from m in query,
      join: mb in Member,
      on: mb.conversation_id == m.conversation_id and mb.user_id == ^me,
      where: m.inserted_at >= mb.joined_at
  end

  defp since_arrival(query, _me, _conversation), do: query

  @doc "Envoie un message après avoir vérifié l'appartenance, le débit, le blocage, l'amitié et l'antivirus."
  def send_message(me, conversation_id, params) do
    attachment = params["attachment"]

    with {:ok, conversation} <- membership(me, conversation_id),
         :ok <- RateLimit.hit(me),
         :ok <- allowed(conversation, me),
         message = %Message{conversation_id: conversation.id, sender_id: me},
         changeset = Message.changeset(message, params, not is_nil(attachment)),
         :ok <- if(changeset.valid?, do: :ok, else: {:error, changeset}),
         {:ok, file} <- Attachments.prepare(attachment),
         {:ok, message} <- insert(conversation, me, changeset, file) do
      Delivery.new_message(conversation, message)
      MlSocial.Notify.new_message(conversation, message)
      {:ok, message}
    end
  end

  defp allowed(%Conversation{kind: "group"}, _me), do: :ok

  defp allowed(conversation, me) do
    other = Conversation.other(conversation, me)

    cond do
      Friends.blocked?(me, other) -> {:error, :blocked}
      not Friends.friends?(me, other) -> {:error, :not_friends}
      true -> :ok
    end
  end

  defp insert(conversation, me, changeset, nil) do
    with {:ok, message} <- locked(conversation, me, fn -> Repo.insert(changeset) end),
         do: {:ok, %{message | attachment: nil}}
  end

  defp insert(conversation, me, changeset, file) do
    key = Attachments.store!(file)

    result =
      locked(conversation, me, fn ->
        with {:ok, message} <- Repo.insert(changeset),
             {:ok, attachment} <- Repo.insert(Attachments.row(file, key, message.id, me)) do
          {:ok, %{message | attachment: attachment}}
        end
      end)

    case result do
      {:ok, _message} ->
        result

      {:error, _reason} ->
        Attachments.delete_file(key)
        result
    end
  end

  defp locked(%Conversation{kind: "group"} = conversation, me, fun) do
    Repo.transact(fn ->
      member =
        Repo.one(
          from m in Member,
            where: m.conversation_id == ^conversation.id and m.user_id == ^me,
            lock: "FOR SHARE"
        )

      if member, do: fun.(), else: {:error, :not_found}
    end)
  end

  defp locked(conversation, me, fun) do
    Friends.with_pair_lock(me, Conversation.other(conversation, me), :shared, fn ->
      with :ok <- allowed(conversation, me), do: fun.()
    end)
  end

  ## Lecture, accusés de lecture et non-lus

  @doc "Marque la conversation comme lue par `me` jusqu'à maintenant (accusé publié si les deux l'autorisent)."
  def mark_read(me, conversation_id) do
    with {:ok, conversation} <- membership(me, conversation_id) do
      now = DateTime.utc_now()

      Repo.update_all(
        from(m in Member, where: m.conversation_id == ^conversation.id and m.user_id == ^me),
        set: [last_read_at: now]
      )

      Delivery.read(conversation.id, me, now)
      Events.broadcast(Events.user(me), {:unread_changed, me})
      MlSocial.Notify.read(me, conversation.id, now)
      :ok
    end
  end

  @doc """
  Messages texte des autres, postérieurs à la dernière lecture de `me` (et, dans un groupe, à son arrivée), ni
  retirés ni masqués, dans les conversations qui ne sont pas en sourdine (compteur global des badges).
  """
  def unread_count(me, now \\ DateTime.utc_now()) do
    blocked = Friends.blocked_either_ids(me)

    from(x in Message,
      join: m in Member,
      on: m.conversation_id == x.conversation_id and m.user_id == ^me,
      join: c in Conversation,
      on: c.id == x.conversation_id,
      where: c.kind != "group" or x.inserted_at >= m.joined_at,
      where: x.sender_id != ^me and x.kind == "text" and is_nil(x.removed_at),
      where: x.sender_id not in ^blocked,
      where: is_nil(m.last_read_at) or x.inserted_at > m.last_read_at,
      where: is_nil(m.muted_until) or m.muted_until <= ^now
    )
    |> Repo.aggregate(:count)
  end

  ## Sourdine

  @doc "Sourdine de la conversation pour `me` : `\"1h\" | \"8h\" | \"24h\" | \"always\"`."
  def mute(me, conversation_id, duration) do
    with {:ok, until} <- mute_until(duration),
         {:ok, conversation} <- membership(me, conversation_id) do
      set_mute(me, conversation, until)
    end
  end

  def unmute(me, conversation_id) do
    with {:ok, conversation} <- membership(me, conversation_id),
         do: set_mute(me, conversation, nil)
  end

  defp mute_until("always"), do: {:ok, Member.forever()}

  defp mute_until(duration) when is_map_key(@mutes, duration),
    do: {:ok, DateTime.add(DateTime.utc_now(), @mutes[duration])}

  defp mute_until(_duration), do: {:error, {:invalid, %{duration: ["is invalid"]}}}

  defp set_mute(me, conversation, until) do
    Repo.update_all(
      from(m in Member, where: m.conversation_id == ^conversation.id and m.user_id == ^me),
      set: [muted_until: until]
    )

    Events.broadcast(Events.user(me), {:unread_changed, me})
    Events.broadcast(Events.user(me), {:conversation_changed, conversation.id})
    get(me, conversation.id)
  end

  @doc "Sourdines en cours de `user_id` : `[{conversation_id, muted_until | nil (sans fin)}]`."
  def mutes(user_id, now \\ DateTime.utc_now()) do
    Repo.all(
      from m in Member,
        where: m.user_id == ^user_id and m.muted_until > ^now,
        order_by: m.conversation_id
    )
    |> Enum.map(fn m -> {m.conversation_id, elem(Member.mute_state(m, now), 1)} end)
  end

  @doc "La conversation, si `me` en est membre actuel : `{:ok, conversation}` ou `{:error, :not_found}`."
  def membership(me, conversation_id) do
    with {:ok, id} <- Ecto.UUID.cast(conversation_id),
         %Conversation{} = conversation <-
           Repo.one(
             from c in Conversation,
               join: m in Member,
               on: m.conversation_id == c.id and m.user_id == ^me,
               where: c.id == ^id
           ) do
      {:ok, conversation}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast_user(user_id) do
    with :error <- Ecto.UUID.cast(user_id), do: {:error, {:invalid, %{user_id: ["is invalid"]}}}
  end
end
