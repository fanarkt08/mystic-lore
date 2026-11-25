defmodule MlLearning.Progress do
  @moduledoc """
  Inscriptions, progression par leçon, XP et tableau de bord.
  L'XP est idempotente par `(user_id, ref_key)` et les jours sont des jours UTC.
  """
  import Ecto.Query
  alias MlLearning.{Catalog, Gamification, Repo}
  alias MlLearning.Catalog.{Adventure, Lesson}
  alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}

  @per_level 150
  @adventure_bonus 50

  ## Aventures

  @doc "Inscription idempotente."
  def enroll(user_id, %Adventure{id: adventure_id}) do
    now = now()
    row = %{id: Ecto.UUID.generate(), user_id: user_id, adventure_id: adventure_id}

    Repo.insert_all(Enrollment, [Map.merge(row, %{inserted_at: now, updated_at: now})],
      on_conflict: :nothing,
      conflict_target: [:user_id, :adventure_id]
    )

    :ok
  end

  @doc "État de l'utilisateur (`nil` = anonyme) sur une aventure dont les leçons sont préchargées."
  def state(user_id, %Adventure{id: id} = adventure) do
    case user_id && Repo.get_by(Enrollment, user_id: user_id, adventure_id: id) do
      nil -> %{enrolled: false, completed: MapSet.new(), progress: nil, resume_lesson_id: nil}
      enrollment -> enrolled_state(enrollment, adventure)
    end
  end

  defp enrolled_state(%Enrollment{} = enrollment, adventure) do
    lessons = Catalog.lessons(adventure)
    completed = completed_ids(enrollment.user_id, adventure.id)
    total = length(lessons)
    done = Enum.count(lessons, &MapSet.member?(completed, &1.id))

    %{
      enrolled: true,
      completed: completed,
      progress: %{
        done: done,
        total: total,
        percent: if(total == 0, do: 0, else: round(done * 100 / total))
      },
      resume_lesson_id: resume(lessons, completed, enrollment.last_lesson_id)
    }
  end

  # Première leçon non terminée à partir de la dernière ouverte, puis depuis le début ; nil si tout est fait.
  defp resume(lessons, completed, last_lesson_id) do
    {before, from_last} =
      Enum.split(lessons, Enum.find_index(lessons, &(&1.id == last_lesson_id)) || 0)

    List.first(for l <- from_last ++ before, not MapSet.member?(completed, l.id), do: l.id)
  end

  ## Leçons (l'accès a été vérifié par l'appelant)

  @doc "Ouvre une leçon : inscription implicite, dernière leçon mémorisée."
  def open(user_id, %Lesson{} = lesson) do
    Repo.transact(fn ->
      touch!(user_id, lesson)
      {:ok, Repo.one!(progress_query(user_id, lesson))}
    end)
  end

  @doc "Compte une tentative et termine la leçon si elle est correcte : `{:ok, :awarded | :duplicate | :none}`."
  def submit(user_id, %Lesson{} = lesson, correct?) do
    Repo.transact(fn -> record_submit(user_id, lesson, correct?) end)
    |> after_progress(user_id)
  end

  @doc "Termine une leçon sans réponse (`story`) : `{:ok, :awarded | :duplicate}`."
  def complete(user_id, %Lesson{} = lesson) do
    Repo.transact(fn -> record_complete(user_id, lesson) end)
    |> after_progress(user_id)
  end

  @doc "Corps transactionnel de `submit/3`, réutilisé par le rejeu hors ligne."
  def record_submit(user_id, %Lesson{} = lesson, correct?) do
    touch!(user_id, lesson)

    Repo.update_all(progress_query(user_id, lesson),
      inc: [attempts: 1],
      set: [updated_at: now()]
    )

    {:ok, if(correct?, do: complete!(user_id, lesson), else: :none)}
  end

  @doc "Corps transactionnel de `complete/2` (voir `record_submit/3`)."
  def record_complete(user_id, %Lesson{} = lesson) do
    touch!(user_id, lesson)
    {:ok, complete!(user_id, lesson)}
  end

  @doc "Réévalue badges et quêtes après la validation, si de l'XP a été accordée."
  def after_progress({:ok, :awarded} = result, user_id) do
    Gamification.after_xp(user_id)
    result
  end

  def after_progress(result, _user_id), do: result

  @doc "Enregistre les notes ou le brouillon de l'utilisateur pour une leçon."
  def save_text(user_id, %Lesson{} = lesson, field, text) when field in [:notes, :draft] do
    now = now()

    stamps =
      if field == :notes, do: [updated_at: now, notes_saved_at: now], else: [updated_at: now]

    {:ok, _} =
      Repo.transact(fn ->
        touch!(user_id, lesson)
        {:ok, Repo.update_all(progress_query(user_id, lesson), set: [{field, text} | stamps])}
      end)

    if field == :notes and String.trim(text) != "", do: Gamification.settle_quests(user_id)
    :ok
  end

  defp touch!(user_id, %Lesson{id: lesson_id, chapter: %{adventure_id: adventure_id}}) do
    now = now()
    stamps = %{inserted_at: now, updated_at: now}

    Repo.insert_all(
      Enrollment,
      [
        Map.merge(stamps, %{
          id: Ecto.UUID.generate(),
          user_id: user_id,
          adventure_id: adventure_id,
          last_lesson_id: lesson_id
        })
      ],
      on_conflict: [set: [last_lesson_id: lesson_id, updated_at: now]],
      conflict_target: [:user_id, :adventure_id]
    )

    Repo.insert_all(
      LessonProgress,
      [Map.merge(stamps, %{id: Ecto.UUID.generate(), user_id: user_id, lesson_id: lesson_id})],
      on_conflict: :nothing,
      conflict_target: [:user_id, :lesson_id]
    )
  end

  defp complete!(user_id, %Lesson{chapter: %{adventure_id: adventure_id}} = lesson) do
    now = now()

    progress_query(user_id, lesson)
    |> where([p], p.status != "completed")
    |> Repo.update_all(set: [status: "completed", completed_at: now, updated_at: now])

    xp = award_xp(user_id, "lesson:#{lesson.id}", lesson.xp_reward)

    if adventure_done?(user_id, adventure_id) do
      award_xp(user_id, "adventure:#{adventure_id}", @adventure_bonus)

      from(e in Enrollment,
        where:
          e.user_id == ^user_id and e.adventure_id == ^adventure_id and is_nil(e.completed_at)
      )
      |> Repo.update_all(set: [completed_at: now])
    end

    xp
  end

  defp adventure_done?(user_id, adventure_id) do
    {total, done} =
      Repo.one(
        from l in Lesson,
          join: c in assoc(l, :chapter),
          left_join: p in LessonProgress,
          on: p.lesson_id == l.id and p.user_id == ^user_id and p.status == "completed",
          where: c.adventure_id == ^adventure_id,
          select: {count(l.id), count(p.id)}
      )

    total > 0 and done == total
  end

  defp progress_query(user_id, %Lesson{id: lesson_id}),
    do: from(p in LessonProgress, where: p.user_id == ^user_id and p.lesson_id == ^lesson_id)

  defp completed_ids(user_id, adventure_id) do
    from(p in LessonProgress,
      join: l in assoc(p, :lesson),
      join: c in assoc(l, :chapter),
      where:
        p.user_id == ^user_id and p.status == "completed" and c.adventure_id == ^adventure_id,
      select: p.lesson_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  ## XP et tableau de bord

  @doc "Attribue `amount` XP au plus une fois par `(user_id, ref_key)`, même en concurrence : `:awarded` ou `:duplicate`."
  def award_xp(user_id, ref_key, amount) do
    row = %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      ref_key: ref_key,
      amount: amount,
      inserted_at: now()
    }

    case Repo.insert_all(XpEvent, [row],
           on_conflict: :nothing,
           conflict_target: [:user_id, :ref_key]
         ) do
      {1, _} -> :awarded
      {0, _} -> :duplicate
    end
  end

  @doc "Construit le tableau de bord : XP, niveau, série, semaine, aventure en cours et recommandations."
  def dashboard(user_id, today \\ Date.utc_today(), categories \\ []) do
    by_day = xp_by_day(user_id)
    %{xp: xp} = stats = stats(by_day, today)

    Map.merge(stats, %{
      into_level: rem(xp, @per_level),
      per_level: @per_level,
      week:
        Enum.map(
          -6..0//1,
          &%{date: Date.add(today, &1), xp: Map.get(by_day, Date.add(today, &1), 0)}
        ),
      current: current(user_id),
      recommendations: recommendations(user_id, categories)
    })
  end

  @doc "`%{xp, level, streak}` de l'utilisateur (mêmes règles que le tableau de bord)."
  def xp_stats(user_id, today \\ Date.utc_today()), do: stats(xp_by_day(user_id), today)

  @doc "Nombre d'aventures terminées."
  def adventures_completed(user_id),
    do:
      Repo.aggregate(
        from(e in Enrollment, where: e.user_id == ^user_id and not is_nil(e.completed_at)),
        :count
      )

  defp xp_by_day(user_id) do
    from(e in XpEvent,
      where: e.user_id == ^user_id,
      group_by: fragment("?::date", e.inserted_at),
      select: {fragment("?::date", e.inserted_at), sum(e.amount)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp stats(by_day, today) do
    xp = by_day |> Map.values() |> Enum.sum()
    streak_from = if Map.has_key?(by_day, today), do: today, else: Date.add(today, -1)
    %{xp: xp, level: div(xp, @per_level) + 1, streak: streak(by_day, streak_from)}
  end

  defp streak(by_day, day),
    do: if(Map.has_key?(by_day, day), do: 1 + streak(by_day, Date.add(day, -1)), else: 0)

  defp current(user_id) do
    query =
      from e in Enrollment,
        where: e.user_id == ^user_id and is_nil(e.completed_at),
        order_by: [desc: e.updated_at, desc: e.inserted_at],
        limit: 1,
        preload: :adventure

    with %Enrollment{adventure: adventure} = enrollment <- Repo.one(query) do
      state = enrolled_state(enrollment, Catalog.with_lessons(adventure))

      %{
        slug: adventure.slug,
        title: adventure.title,
        percent: state.progress.percent,
        resume_lesson_id: state.resume_lesson_id
      }
    end
  end

  # Non commencées ; catégories préférées d'abord (dans l'ordre donné), puis gratuites, puis par titre.
  defp recommendations(user_id, categories) do
    enrolled = from(e in Enrollment, where: e.user_id == ^user_id, select: e.adventure_id)
    rank = length(categories) + 1

    Repo.all(
      from a in Adventure,
        where: a.id not in subquery(enrolled),
        order_by: [
          asc:
            fragment("coalesce(array_position(?::text[], ?), ?)", ^categories, a.category, ^rank),
          asc: a.premium,
          asc: a.title
        ],
        limit: 3
    )
  end

  defp now, do: DateTime.utc_now(:second)
end
