defmodule MlCommunity.Posts do
  @moduledoc """
  Publications des membres : discussions, réponses, édition pendant 30 minutes, suppression, solution et suivi.
  Un membre restreint ne publie plus, et la publication est refusée si accounts est injoignable.
  """
  import Ecto.Changeset
  import Ecto.Query
  require Logger
  alias MlCommunity.{Category, Discussion, Follow, Forum, Reply, Repo, Social, Viewer}
  alias MlShared.Events

  @edit_window_s 30 * 60
  @rate_limit 10
  @rate_window_s 10 * 60

  ## Discussions

  @doc "Crée une discussion, dans la limite de 10 publications par 10 minutes."
  def create_discussion(%Viewer{id: me} = viewer, attrs) do
    changeset = Discussion.create_changeset(%Discussion{author_id: me}, attrs)

    with :ok <- Viewer.can_publish(viewer),
         {:ok, changeset} <- check_category(changeset, viewer) do
      now = DateTime.utc_now()

      changeset
      |> change(slug: Discussion.slug(get_field(changeset, :title)), last_activity_at: now)
      |> insert_post(me, fn discussion -> follow!(me, discussion.id) end)
    end
  end

  defp check_category(%{valid?: false} = changeset, _viewer), do: {:error, changeset}

  defp check_category(changeset, viewer) do
    case Repo.get(Category, get_field(changeset, :category)) do
      nil ->
        {:error, add_error(changeset, :category, "is invalid")}

      category ->
        if Forum.can_post?(category, viewer), do: {:ok, changeset}, else: {:error, :forbidden}
    end
  end

  @doc "Édition du titre et du corps par l'auteur, dans les 30 minutes."
  def update_discussion(viewer, slug, attrs) do
    with :ok <- Viewer.can_publish(viewer),
         {:ok, discussion} <- Forum.fetch_discussion(viewer, slug),
         :ok <- editable(viewer, discussion) do
      discussion
      |> Discussion.edit_changeset(attrs)
      |> put_change(:edited_at, DateTime.utc_now())
      |> Repo.update()
    end
  end

  @doc "Suppression logique par l'auteur (sans délai)."
  def delete_discussion(viewer, slug) do
    with {:ok, discussion} <- Forum.fetch_discussion(viewer, slug),
         :ok <- own(viewer, discussion) do
      discussion |> change(status: "deleted") |> Repo.update!()
      :ok
    end
  end

  ## Réponses

  @doc "Répond à la discussion `slug` si elle est visible et non verrouillée."
  def create_reply(%Viewer{id: me} = viewer, slug, attrs) do
    with :ok <- Viewer.can_publish(viewer),
         {:ok, discussion} <- Forum.fetch_discussion(viewer, slug),
         :ok <- open_for_replies(discussion, viewer),
         {:ok, reply} <-
           %Reply{discussion_id: discussion.id, author_id: me}
           |> Reply.changeset(attrs)
           |> insert_post(me, fn reply ->
             Repo.update_all(from(d in Discussion, where: d.id == ^discussion.id),
               set: [last_activity_at: reply.inserted_at]
             )

             follow!(me, discussion.id)
           end) do
      notify_followers(discussion, reply, viewer)
      {:ok, %{reply | discussion: discussion}}
    end
  end

  defp open_for_replies(%Discussion{status: "visible", locked: false}, _viewer), do: :ok
  defp open_for_replies(%Discussion{status: "visible"}, %Viewer{staff: true}), do: :ok
  defp open_for_replies(%Discussion{status: "visible"}, _viewer), do: {:error, :locked}
  defp open_for_replies(_discussion, _viewer), do: {:error, :forbidden}

  @doc "Édition du corps d'une réponse par son auteur, dans les 30 minutes."
  def update_reply(viewer, reply_id, attrs) do
    with :ok <- Viewer.can_publish(viewer),
         {:ok, reply} <- Forum.fetch_reply(viewer, reply_id),
         :ok <- editable(viewer, reply) do
      reply
      |> Reply.changeset(attrs)
      |> put_change(:edited_at, DateTime.utc_now())
      |> Repo.update()
    end
  end

  @doc "Suppression logique d'une réponse par son auteur ; elle cesse d'être la solution."
  def delete_reply(viewer, reply_id) do
    with {:ok, reply} <- Forum.fetch_reply(viewer, reply_id),
         :ok <- own(viewer, reply) do
      Repo.transact(fn ->
        reply |> change(status: "deleted") |> Repo.update!()
        unset_solution(reply.id)
        {:ok, :deleted}
      end)

      :ok
    end
  end

  @doc "Retire `reply_id` des solutions (réponse supprimée, masquée ou retirée)."
  def unset_solution(reply_id) do
    Repo.update_all(from(d in Discussion, where: d.solution_reply_id == ^reply_id),
      set: [solution_reply_id: nil]
    )
  end

  ## Solution

  @doc "L'auteur de la discussion désigne une réponse visible de celle-ci comme solution (`nil` : aucune)."
  def set_solution(viewer, slug, reply_id) do
    with {:ok, discussion} <- Forum.fetch_discussion(viewer, slug),
         :ok <- solution_owner(viewer, discussion),
         {:ok, solution} <- solution_reply(viewer, discussion, reply_id) do
      discussion |> change(solution_reply_id: solution) |> Repo.update()
    end
  end

  defp solution_owner(%Viewer{id: me}, %Discussion{author_id: me, status: "visible"}), do: :ok
  defp solution_owner(_viewer, _discussion), do: {:error, :forbidden}

  defp solution_reply(_viewer, _discussion, nil), do: {:ok, nil}

  defp solution_reply(viewer, discussion, reply_id) do
    case Forum.fetch_reply(viewer, reply_id) do
      {:ok, %Reply{discussion_id: id, status: "visible"} = reply} when id == discussion.id ->
        {:ok, reply.id}

      _ ->
        {:error, {:invalid, %{reply_id: ["is invalid"]}}}
    end
  end

  ## Suivi

  def follow(viewer, slug) do
    with {:ok, discussion} <- Forum.fetch_discussion(viewer, slug) do
      follow!(viewer.id, discussion.id)
      :ok
    end
  end

  def unfollow(viewer, slug) do
    with {:ok, discussion} <- Forum.fetch_discussion(viewer, slug) do
      Repo.delete_all(
        from f in Follow, where: f.user_id == ^viewer.id and f.discussion_id == ^discussion.id
      )

      :ok
    end
  end

  defp follow!(user_id, discussion_id) do
    Repo.insert_all(
      Follow,
      [%{user_id: user_id, discussion_id: discussion_id, inserted_at: DateTime.utc_now()}],
      on_conflict: :nothing
    )
  end

  # Les abonnés en blocage avec l'auteur ne sont pas notifiés ; si social ne répond pas, personne ne l'est.
  defp notify_followers(discussion, reply, %Viewer{id: me, blocked: blocked}) do
    case Social.blocked_ids(discussion.author_id) do
      {:ok, author_blocked} ->
        excluded = Enum.uniq([me | blocked ++ author_blocked])

        followers =
          Repo.all(
            from f in Follow,
              where: f.discussion_id == ^discussion.id and f.user_id not in ^excluded,
              select: f.user_id
          )

        Enum.each(followers, fn id ->
          Events.broadcast(
            Events.user(id),
            {:community_reply, discussion.slug, discussion.title}
          )

          MlShared.Notifications.async(fn ->
            MlShared.Notifications.notify(%{
              user_id: id,
              category: "community",
              kind: "community_reply",
              actor_id: me,
              params: %{
                discussion_id: discussion.id,
                slug: discussion.slug,
                title: discussion.title
              },
              dedupe_key: "discussion:#{discussion.id}",
              event_id: "reply:#{reply.id}",
              occurred_at: reply.inserted_at
            })
          end)
        end)

      {:error, :unavailable} ->
        Logger.warning("community: reply notifications skipped (social unavailable)")
    end
  end

  ## Règles communes

  @doc "`:ok` si `viewer` peut encore éditer `post` (auteur, contenu visible, moins de 30 minutes)."
  def editable(%Viewer{id: me}, %{author_id: me, status: "visible", inserted_at: at})
      when is_binary(me) do
    if DateTime.diff(DateTime.utc_now(), at) <= @edit_window_s,
      do: :ok,
      else: {:error, :edit_window_expired}
  end

  def editable(_viewer, _post), do: {:error, :forbidden}

  defp own(%Viewer{id: me}, %{author_id: me, status: status})
       when is_binary(me) and status != "deleted",
       do: :ok

  defp own(_viewer, _post), do: {:error, :forbidden}

  defp insert_post(%Ecto.Changeset{valid?: false} = changeset, _me, _after_insert),
    do: {:error, changeset}

  defp insert_post(changeset, me, after_insert) do
    Repo.transact(fn ->
      with :ok <- within_rate_limit(me),
           {:ok, post} <- Repo.insert(changeset) do
        after_insert.(post)
        {:ok, post}
      end
    end)
  end

  defp within_rate_limit(me) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "community:posts:" <> me
    ])

    since = DateTime.add(DateTime.utc_now(), -@rate_window_s, :second)
    recent = recent_count(Discussion, me, since) + recent_count(Reply, me, since)
    if recent < @rate_limit, do: :ok, else: {:error, :rate_limited}
  end

  defp recent_count(schema, me, since),
    do:
      Repo.aggregate(
        from(p in schema, where: p.author_id == ^me and p.inserted_at > ^since),
        :count
      )
end
