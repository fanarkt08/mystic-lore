defmodule MlLearning.Importer do
  @moduledoc """
  Importe une aventure publiée par le studio, en gardant la progression des leçons existantes.
  """
  import Ecto.Query
  alias MlLearning.{Minigame, Repo, Sim, Video}
  alias MlLearning.Catalog.{Adventure, Chapter, Lesson}
  alias MlLearning.Progress.LessonProgress

  @source "studio"
  @categories ~w(coding science humanities creative)
  @difficulties ~w(beginner intermediate advanced)
  @covers ~w(forest observatory alchemy archive)
  @kinds ~w(story exercise coding video simulation minigame)
  @default_xp %{
    "story" => 10,
    "exercise" => 20,
    "coding" => 40,
    "video" => 15,
    "simulation" => 30,
    "minigame" => 25
  }

  @doc "`{:ok, %{adventure_id, slug, version}}`, `{:error, :stale_version}` ou `{:error, {:invalid, errors}}`."
  def import(params) when is_map(params) do
    with {:ok, data} <- validate(params) do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "import:" <> data.external_id
        ])

        case Repo.one(
               from a in Adventure,
                 where: a.source == @source and a.external_id == ^data.external_id
             ) do
          %Adventure{imported_version: v} = adv when v == data.version ->
            result(adv)

          %Adventure{imported_version: v} when v > data.version ->
            Repo.rollback(:stale_version)

          existing ->
            existing |> upsert_adventure(data) |> sync_chapters(data.chapters) |> result()
        end
      end)
    end
  end

  defp result(%Adventure{} = adv),
    do: %{adventure_id: adv.id, slug: adv.slug, version: adv.imported_version}

  ## Écriture

  defp upsert_adventure(existing, data) do
    attrs = %{
      title: data.title,
      summary: data.summary,
      description: data.description,
      category: data.category,
      difficulty: data.difficulty,
      premium: false,
      duration_minutes: data.duration_minutes,
      cover: data.cover,
      objectives: data.objectives,
      prerequisites: data.prerequisites,
      author_id: data.author_id,
      imported_version: data.version
    }

    case existing do
      nil ->
        Repo.insert!(
          struct(
            Adventure,
            Map.merge(attrs, %{
              slug: unique_slug(data.title),
              source: @source,
              external_id: data.external_id
            })
          )
        )

      %Adventure{} = adv ->
        adv |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  defp sync_chapters(%Adventure{} = adv, chapters) do
    existing = Repo.all(from c in Chapter, where: c.adventure_id == ^adv.id, order_by: c.position)
    park(Chapter, :adventure_id, adv.id)

    {kept, extra} = Enum.split(existing, length(chapters))

    kept_or_new =
      chapters
      |> Enum.with_index(1)
      |> Enum.map(fn {ch, pos} ->
        case Enum.at(kept, pos - 1) do
          nil -> Repo.insert!(%Chapter{adventure_id: adv.id, position: pos, title: ch.title})
          old -> old |> Ecto.Changeset.change(position: pos, title: ch.title) |> Repo.update!()
        end
      end)

    Enum.zip(kept_or_new, chapters)
    |> Enum.each(fn {chapter, ch} -> sync_lessons(chapter, ch.lessons) end)

    # chapitres en trop : supprimés sans progression, sinon conservés à la fin
    extra
    |> Enum.reject(&delete_if_unused_chapter/1)
    |> Enum.with_index(length(chapters) + 1)
    |> Enum.each(fn {c, pos} -> c |> Ecto.Changeset.change(position: pos) |> Repo.update!() end)

    adv
  end

  defp sync_lessons(%Chapter{} = chapter, lessons) do
    existing =
      Repo.all(from l in Lesson, where: l.chapter_id == ^chapter.id, order_by: l.position)

    park(Lesson, :chapter_id, chapter.id)
    {kept, extra} = Enum.split(existing, length(lessons))

    lessons
    |> Enum.with_index(1)
    |> Enum.each(fn {l, pos} ->
      fields = [
        position: pos,
        title: l.title,
        kind: l.kind,
        body: l.body,
        content: l.content,
        solution: l.solution,
        xp_reward: l.xp_reward
      ]

      case Enum.at(kept, pos - 1) do
        nil -> Repo.insert!(struct(Lesson, [chapter_id: chapter.id] ++ fields))
        old -> old |> Ecto.Changeset.change(fields) |> Repo.update!()
      end
    end)

    extra
    |> Enum.reject(&delete_if_unused_lesson/1)
    |> Enum.with_index(length(lessons) + 1)
    |> Enum.each(fn {l, pos} -> l |> Ecto.Changeset.change(position: pos) |> Repo.update!() end)
  end

  # positions temporaires négatives : évite les collisions de l'index unique pendant la renumérotation
  defp park(schema, parent_field, parent_id) do
    from(x in schema,
      where: field(x, ^parent_field) == ^parent_id,
      update: [set: [position: fragment("-1000 - ?", x.position)]]
    )
    |> Repo.update_all([])

    :ok
  end

  defp delete_if_unused_lesson(%Lesson{id: id} = lesson) do
    if Repo.exists?(from p in LessonProgress, where: p.lesson_id == ^id),
      do: false,
      else:
        (
          Repo.delete!(lesson)
          true
        )
  end

  defp delete_if_unused_chapter(%Chapter{id: id} = chapter) do
    lesson_ids = from(l in Lesson, where: l.chapter_id == ^id, select: l.id)

    if Repo.exists?(from p in LessonProgress, where: p.lesson_id in subquery(lesson_ids)),
      do: false,
      else:
        (
          Repo.delete!(chapter)
          true
        )
  end

  defp unique_slug(title) do
    base =
      title
      |> String.normalize(:nfd)
      |> String.replace(~r/[^A-Za-z0-9\s-]/u, "")
      |> String.downcase()
      |> String.replace(~r/[\s-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 60)
      |> then(&if(&1 == "", do: "adventure", else: &1))

    if Repo.exists?(from a in Adventure, where: a.slug == ^base),
      do: base <> "-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)),
      else: base
  end

  ## Validation (toutes les erreurs sont renvoyées ensemble)

  defp validate(p) do
    adv = map(p["adventure"])

    {data, errors} =
      {%{}, %{}}
      |> check(:external_id, uuid(p["external_id"]), "must be a UUID")
      |> check(:version, int(p["version"], 1, 1_000_000), "must be a positive integer")
      |> check(:title, text(adv["title"], 1, 120), "must be 1 to 120 characters")
      |> check(:summary, text(adv["summary"], 1, 300), "must be 1 to 300 characters")
      |> check(
        :description,
        text(adv["description"] || "", 0, 5000),
        "must be at most 5000 characters"
      )
      |> check(:category, member(adv["category"], @categories), "is invalid")
      |> check(:difficulty, member(adv["difficulty"], @difficulties), "is invalid")
      |> check(:cover, member(adv["cover"] || "forest", @covers), "is invalid")
      |> check(:duration_minutes, int(adv["duration_minutes"], 1, 600), "must be 1 to 600")
      |> check(
        :objectives,
        strings(adv["objectives"] || [], 10, 200),
        "at most 10 items of 200 characters"
      )
      |> check(
        :prerequisites,
        strings(adv["prerequisites"] || [], 10, 200),
        "at most 10 items of 200 characters"
      )
      |> check(
        :author_id,
        if(adv["author_id"], do: uuid(adv["author_id"]), else: {:ok, nil}),
        "must be a UUID"
      )
      |> check(
        :chapters,
        chapters(adv["chapters"]),
        "must contain 1 to 20 chapters of 1 to 30 valid lessons"
      )

    if errors == %{}, do: {:ok, data}, else: {:error, {:invalid, errors}}
  end

  defp check({data, errors}, key, {:ok, value}, _msg), do: {Map.put(data, key, value), errors}

  defp check({data, errors}, key, {:error, detail}, _msg) when is_binary(detail),
    do: {data, Map.put(errors, key, [detail])}

  defp check({data, errors}, key, _error, msg), do: {data, Map.put(errors, key, [msg])}

  defp map(m) when is_map(m), do: m
  defp map(_), do: %{}

  defp uuid(v) do
    case is_binary(v) && Ecto.UUID.cast(v) do
      {:ok, id} -> {:ok, id}
      _ -> :error
    end
  end

  defp int(v, min, max) when is_integer(v) and v >= min and v <= max, do: {:ok, v}
  defp int(_, _, _), do: :error

  defp text(v, min, max) when is_binary(v) do
    t = String.trim(v)
    if String.length(t) in min..max and not String.contains?(t, <<0>>), do: {:ok, t}, else: :error
  end

  defp text(_, _, _), do: :error

  defp member(v, list), do: if(v in list, do: {:ok, v}, else: :error)

  defp strings(list, max_items, max_len) when is_list(list) and length(list) <= max_items do
    trimmed = Enum.map(list, &text(&1, 1, max_len))

    if Enum.all?(trimmed, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(trimmed, &elem(&1, 1))},
      else: :error
  end

  defp strings(_, _, _), do: :error

  defp chapters(list) when is_list(list) and length(list) in 1..20 do
    parsed =
      Enum.with_index(list, 1)
      |> Enum.map(fn {ch, i} ->
        ch = map(ch)

        with {:ok, title} <- text(ch["title"], 1, 120),
             lessons when is_list(lessons) and length(lessons) in 1..30 <- ch["lessons"],
             {:ok, lessons} <- lessons(lessons, i) do
          {:ok, %{title: title, lessons: lessons}}
        else
          {:error, detail} -> {:error, detail}
          _ -> {:error, "chapter #{i}: title (1-120 characters) and 1 to 30 lessons are required"}
        end
      end)

    case Enum.find(parsed, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(parsed, &elem(&1, 1))}
      error -> error
    end
  end

  defp chapters(_), do: :error

  defp lessons(list, chapter_index) do
    parsed =
      list
      |> Enum.with_index(1)
      |> Enum.map(fn {l, j} ->
        case lesson(map(l)) do
          {:ok, lesson} ->
            {:ok, lesson}

          error ->
            detail =
              case error do
                {:error, message} -> " (#{message})"
                _ -> ""
              end

            {:error,
             "chapter #{chapter_index}, lesson #{j}: invalid #{inspect(map(l)["kind"])} lesson" <>
               detail}
        end
      end)

    case Enum.find(parsed, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(parsed, &elem(&1, 1))}
      error -> error
    end
  end

  defp lesson(%{"kind" => kind} = l) when kind in @kinds do
    with {:ok, title} <- text(l["title"], 1, 120),
         {:ok, body} <- text(l["body"] || "", 0, 20_000),
         {:ok, xp} <- int(l["xp_reward"] || @default_xp[kind], 1, 100),
         {:ok, content, solution} <- kind_fields(kind, l) do
      {:ok,
       %{
         title: title,
         kind: kind,
         body: body,
         xp_reward: xp,
         content: content,
         solution: solution
       }}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> :error
    end
  end

  defp lesson(_), do: :error

  defp kind_fields("story", _l), do: {:ok, %{}, %{}}

  defp kind_fields("exercise", l) do
    content = map(l["content"])

    with {:ok, question} <- text(content["question"], 1, 500),
         {:ok, choices} <- strings(content["choices"] || [], 6, 200),
         true <- length(choices) >= 2 and length(Enum.uniq(choices)) == length(choices),
         {:ok, index} <- int(l["solution"], 0, length(choices) - 1),
         {:ok, explanation} <- text(l["explanation"] || "Correct!", 1, 1000) do
      {:ok, %{"question" => question, "choices" => choices},
       %{
         "answer" => Enum.at(choices, index),
         "explanation" => explanation,
         "hint" => "Not quite. Try again."
       }}
    else
      _ -> :error
    end
  end

  defp kind_fields("coding", l) do
    content = map(l["content"])

    with {:ok, plants} <- int(content["plants"], 2, 10),
         {:ok, starter} <- text(content["starter"] || "", 0, 600),
         {:ok, hints} <- strings(content["hints"] || [], 5, 300) do
      {:ok,
       %{
         "plants" => plants,
         "starter" => starter,
         "hints" => hints,
         "language_note" =>
           "Grove language: for <name> in range(n): then an indented water(<name>). It is a tiny bounded language, not Python."
       }, %{}}
    else
      _ -> :error
    end
  end

  # Les chemins vidéo sont construits à partir des identifiants de médias, jamais repris d'une URL reçue.
  defp kind_fields("video", l) do
    c = map(l["content"])
    video = map(c["video"])

    with {:ok, video_id} <- uuid(video["media_id"]),
         captions when is_list(captions) <- c["captions"],
         {:ok, captions} <- media_captions(captions),
         {:ok, content} <-
           Video.validate(%{
             "video" => %{
               "src" => "/media/studio/" <> video_id,
               "type" => video["content_type"],
               "poster" => nil
             },
             "captions" => captions,
             "transcript" => c["transcript"],
             "duration_s" => c["duration_s"]
           }) do
      {:ok, content, %{}}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "video.media_id and captions[].media_id must be media UUIDs"}
    end
  end

  defp kind_fields("simulation", l), do: Sim.validate(map(l["content"]), map(l["solution"]))
  defp kind_fields("minigame", l), do: Minigame.build(map(l["content"]))

  defp media_captions(list) do
    parsed =
      for c <- list do
        c = map(c)

        case uuid(c["media_id"]) do
          {:ok, id} ->
            %{"lang" => c["lang"], "label" => c["label"], "src" => "/media/studio/" <> id}

          :error ->
            nil
        end
      end

    if Enum.all?(parsed), do: {:ok, parsed}, else: :error
  end
end
