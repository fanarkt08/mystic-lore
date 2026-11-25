defmodule MlLearning.Catalog do
  @moduledoc "Catalogue en lecture : liste filtrée et paginée, détail avec chapitres et leçons, leçon seule."
  import Ecto.Query
  alias MlLearning.Repo
  alias MlLearning.Catalog.{Adventure, Chapter, Lesson}

  @per_page 6

  @doc "Renvoie une page de 6 aventures, filtrée par `q`, `category`, `difficulty` et `access`, et triée par `sort`."
  def list_adventures(params) do
    query =
      Adventure
      |> search(params["q"])
      |> filter(:category, params["category"])
      |> filter(:difficulty, params["difficulty"])
      |> access(params["access"])

    page = page(params["page"])
    total = Repo.aggregate(query, :count)

    entries =
      query |> sort(params["sort"]) |> limit(@per_page) |> offset(^((page - 1) * @per_page))

    %{
      entries: Repo.all(entries),
      page: page,
      total: total,
      total_pages: max(div(total + @per_page - 1, @per_page), 1)
    }
  end

  defp search(query, q) when is_binary(q) do
    case q |> String.trim() |> String.slice(0, 100) do
      "" ->
        query

      q ->
        pattern = "%" <> String.replace(q, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
        where(query, [a], ilike(a.title, ^pattern) or ilike(a.summary, ^pattern))
    end
  end

  defp search(query, _), do: query

  defp filter(query, field, value) when is_binary(value) and value != "",
    do: where(query, [a], field(a, ^field) == ^value)

  defp filter(query, _field, _value), do: query

  defp access(query, "free"), do: where(query, [a], not a.premium)
  defp access(query, "premium"), do: where(query, [a], a.premium)
  defp access(query, _), do: query

  defp sort(query, "newest"),
    do: order_by(query, [a], desc: a.inserted_at, asc: a.title, asc: a.id)

  defp sort(query, "shortest"),
    do: order_by(query, [a], asc: a.duration_minutes, asc: a.title, asc: a.id)

  defp sort(query, _), do: order_by(query, [a], asc: a.title, asc: a.id)

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, 10_000)
      _ -> 1
    end
  end

  defp page(_), do: 1

  @doc "Aventure par slug, chapitres et leçons préchargés dans l'ordre."
  def fetch_adventure(slug) do
    case Repo.get_by(Adventure, slug: slug) do
      nil -> {:error, :not_found}
      adventure -> {:ok, with_lessons(adventure)}
    end
  end

  def with_lessons(adventure) do
    lessons = from(l in Lesson, order_by: l.position)
    chapters = from(c in Chapter, order_by: c.position, preload: [lessons: ^lessons])
    Repo.preload(adventure, chapters: chapters)
  end

  @doc "Leçons d'une aventure préchargée, dans l'ordre de lecture."
  def lessons(%Adventure{chapters: chapters}), do: Enum.flat_map(chapters, & &1.lessons)

  @doc "Leçon par identifiant, avec son chapitre et son aventure."
  def fetch_lesson(id) do
    with {:ok, id} <- MlLearning.cast_uuid(id),
         %Lesson{} = lesson <-
           Repo.one(from l in Lesson, where: l.id == ^id, preload: [chapter: :adventure]) do
      {:ok, lesson}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "`{prev_id, next_id}` d'une leçon dans toute son aventure (chapitres puis leçons)."
  def neighbours(%Lesson{id: id, chapter: %Chapter{adventure_id: adventure_id}}) do
    ids =
      Repo.all(
        from l in Lesson,
          join: c in assoc(l, :chapter),
          where: c.adventure_id == ^adventure_id,
          order_by: [c.position, l.position],
          select: l.id
      )

    index = Enum.find_index(ids, &(&1 == id))
    {if(index > 0, do: Enum.at(ids, index - 1)), Enum.at(ids, index + 1)}
  end
end
