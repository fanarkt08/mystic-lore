defmodule MlCommunity.Forum do
  @moduledoc """
  Lecture du forum pour un lecteur. La visibilité et les blocages sont appliqués dans chaque requête,
  jamais en filtrant après coup.
  """
  import Ecto.Query
  alias MlCommunity.{Category, Discussion, Follow, Reply, Repo, Viewer, Vote}

  @per_page 10
  @replies_per_page 50

  def categories, do: Repo.all(from c in Category, order_by: c.position)

  @doc "Un membre peut ouvrir une discussion dans `category` (les catégories `staff_only` sont réservées au staff)."
  def can_post?(%Category{staff_only: staff_only}, %Viewer{id: id, staff: staff}),
    do: id != nil and (staff or not staff_only)

  ## Visibilité

  @doc "Restreint la liaison nommée `binding` (discussion ou réponse) aux lignes que `viewer` peut voir."
  def visible(query, %Viewer{} = viewer, binding) do
    query |> by_status(viewer, binding) |> not_blocked(viewer.blocked, binding)
  end

  defp by_status(query, %Viewer{staff: true}, _binding), do: query

  defp by_status(query, %Viewer{id: nil}, b),
    do: where(query, [{^b, x}], x.status == "visible")

  defp by_status(query, %Viewer{id: me}, b) do
    where(
      query,
      [{^b, x}],
      x.status == "visible" or (x.author_id == ^me and x.status in ["hidden", "removed"])
    )
  end

  defp not_blocked(query, [], _binding), do: query
  defp not_blocked(query, ids, b), do: where(query, [{^b, x}], x.author_id not in ^ids)

  ## Discussions

  @doc "Liste les discussions visibles, 10 par page, avec recherche, catégorie, filtre et tri."
  def list_discussions(viewer, params) do
    from(d in Discussion, as: :d)
    |> visible(viewer, :d)
    |> search(params["q"])
    |> in_category(params["category"])
    |> filter(params["filter"], viewer)
    |> MlCommunity.paginate(
      params["page"],
      @per_page,
      &(&1 |> sort(params["sort"]) |> with_viewer(viewer))
    )
  end

  @doc "Discussion `slug` visible par `viewer`, avec ses champs calculés."
  def fetch_discussion(viewer, slug) when is_binary(slug) do
    from(d in Discussion, as: :d, where: d.slug == ^slug)
    |> visible(viewer, :d)
    |> with_viewer(viewer)
    |> Repo.one()
    |> found()
  end

  def fetch_discussion(_viewer, _slug), do: {:error, :not_found}

  @doc "Discussion d'identifiant `id` visible par `viewer`."
  def fetch_discussion_by_id(viewer, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        from(d in Discussion, as: :d, where: d.id == ^id)
        |> visible(viewer, :d)
        |> Repo.one()
        |> found()

      :error ->
        {:error, :not_found}
    end
  end

  defp search(query, q) when is_binary(q) do
    case q |> String.trim() |> String.slice(0, 100) do
      "" ->
        query

      q ->
        pattern = "%" <> String.replace(q, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
        where(query, [d: d], ilike(d.title, ^pattern) or ilike(d.body, ^pattern))
    end
  end

  defp search(query, _q), do: query

  defp in_category(query, slug) when is_binary(slug) and slug != "",
    do: where(query, [d: d], d.category == ^slug)

  defp in_category(query, _slug), do: query

  defp filter(query, "unanswered", viewer),
    do: where(query, [d: d], not exists(counted_replies(viewer)))

  defp filter(query, "solved", _viewer), do: where(query, [d: d], not is_nil(d.solution_reply_id))
  defp filter(query, "following", %Viewer{id: nil}), do: where(query, false)

  defp filter(query, "following", %Viewer{id: me}),
    do: where(query, [d: d], exists(followed(me)))

  defp filter(query, _filter, _viewer), do: query

  defp sort(query, "helpful"),
    do: order_by(query, [d: d], desc: d.helpful_count, desc: d.last_activity_at, desc: d.id)

  defp sort(query, _sort),
    do: order_by(query, [d: d], desc: d.pinned, desc: d.last_activity_at, desc: d.id)

  # Réponses comptées pour la discussion `parent_as(:d)` : visibles et hors membres bloqués.
  defp counted_replies(viewer) do
    from(r in Reply, as: :r, where: r.discussion_id == parent_as(:d).id and r.status == "visible")
    |> not_blocked(viewer.blocked, :r)
  end

  defp followed(me),
    do: from(f in Follow, where: f.discussion_id == parent_as(:d).id and f.user_id == ^me)

  # Nom de la catégorie, réponses visibles pour ce lecteur, et pour un membre : suivi et vote.
  defp with_viewer(query, viewer) do
    query =
      query
      |> join(:inner, [d: d], c in Category, as: :c, on: c.slug == d.category)
      |> select_merge([c: c], %{
        category_name: c.name,
        reply_count: subquery(select(counted_replies(viewer), [r], count()))
      })

    case viewer.id do
      nil ->
        query

      me ->
        voted =
          from v in Vote,
            where:
              v.target_type == "discussion" and v.target_id == parent_as(:d).id and
                v.user_id == ^me

        select_merge(query, %{following: exists(followed(me)), voted: exists(voted)})
    end
  end

  ## Réponses

  @doc "Réponses visibles de `discussion`, en ordre chronologique, 50 par page."
  def list_replies(viewer, %Discussion{id: id}, page) do
    from(r in Reply, as: :r, where: r.discussion_id == ^id)
    |> visible(viewer, :r)
    |> MlCommunity.paginate(page, @replies_per_page, fn query ->
      query |> order_by([r: r], asc: r.inserted_at, asc: r.id) |> with_vote(viewer)
    end)
  end

  defp with_vote(query, %Viewer{id: nil}), do: query

  defp with_vote(query, %Viewer{id: me}) do
    voted =
      from v in Vote,
        where: v.target_type == "reply" and v.target_id == parent_as(:r).id and v.user_id == ^me

    select_merge(query, %{voted: exists(voted)})
  end

  @doc "Réponse `id` visible par `viewer`, dans une discussion qu'il peut voir (préchargée dans `discussion`)."
  def fetch_reply(viewer, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {%Reply{} = reply, discussion} <-
           from(r in Reply,
             as: :r,
             join: d in Discussion,
             as: :d,
             on: d.id == r.discussion_id,
             where: r.id == ^id,
             select: {r, d}
           )
           |> visible(viewer, :r)
           |> visible(viewer, :d)
           |> Repo.one() do
      {:ok, %{reply | discussion: discussion}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp found(nil), do: {:error, :not_found}
  defp found(record), do: {:ok, record}
end
