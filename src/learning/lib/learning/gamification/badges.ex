defmodule MlLearning.Gamification.Badges do
  @moduledoc """
  Attribution, progression et équipement des badges. Un badge gagné n'est jamais retiré.
  """
  import Ecto.Query
  alias MlLearning.{Progress, Repo}
  alias MlLearning.Gamification.{Badge, UserBadge}
  alias MlLearning.Progress.{LessonProgress, XpEvent}

  @max_equipped 3

  def max_equipped, do: @max_equipped

  @doc "Attribue les badges dont le critère est atteint et renvoie ceux gagnés par cet appel."
  def award(user_id, today \\ Date.utc_today()) do
    earned = from(ub in UserBadge, where: ub.user_id == ^user_id, select: ub.badge_id)

    case Repo.all(from b in Badge, where: b.id not in subquery(earned), order_by: b.id) do
      [] ->
        []

      pending ->
        new = insert_earned(user_id, pending, metrics(user_id, today))
        Enum.each(new, &notify(user_id, &1))
        new
    end
  end

  defp notify(user_id, %Badge{} = badge) do
    MlShared.Notifications.async(fn ->
      MlShared.Notifications.notify(%{
        user_id: user_id,
        category: "learning",
        kind: "badge_earned",
        params: %{badge_slug: badge.slug, badge_name: badge.name},
        dedupe_key: "badge:#{badge.slug}"
      })
    end)
  end

  defp insert_earned(user_id, pending, metrics) do
    now = DateTime.utc_now(:second)

    rows =
      for badge <- pending,
          current(badge, metrics) >= badge.target,
          do: %{
            id: Ecto.UUID.generate(),
            user_id: user_id,
            badge_id: badge.id,
            earned_at: now,
            equipped: false
          }

    {_, inserted} =
      Repo.insert_all(UserBadge, rows,
        on_conflict: :nothing,
        conflict_target: [:user_id, :badge_id],
        returning: [:badge_id]
      )

    ids = MapSet.new(inserted, & &1.badge_id)
    Enum.filter(pending, &MapSet.member?(ids, &1.id))
  end

  @doc """
  Tout le catalogue pour l'utilisateur : `%{badges: [%{badge, user_badge | nil, current}], equipped: [même forme]}`
  (`current` = valeur réelle du critère, bornée à la cible ; les badges équipés dans l'ordre des positions).
  """
  def achievements(user_id, today \\ Date.utc_today()) do
    owned =
      Map.new(Repo.all(from ub in UserBadge, where: ub.user_id == ^user_id), &{&1.badge_id, &1})

    badges = Repo.all(from b in Badge, order_by: [b.position, b.slug])
    metrics = if Enum.all?(badges, &owned[&1.id]), do: %{}, else: metrics(user_id, today)

    entries =
      for badge <- badges do
        user_badge = owned[badge.id]
        current = if user_badge, do: badge.target, else: current(badge, metrics)
        %{badge: badge, user_badge: user_badge, current: min(current, badge.target)}
      end

    equipped =
      entries
      |> Enum.filter(&(&1.user_badge && &1.user_badge.equipped))
      |> Enum.sort_by(& &1.user_badge.position)

    %{badges: entries, equipped: equipped}
  end

  @doc "Badges équipés dans l'ordre : `[{badge, position}]`."
  def equipped(user_id),
    do:
      Repo.all(
        from ub in UserBadge,
          join: b in assoc(ub, :badge),
          where: ub.user_id == ^user_id and ub.equipped,
          order_by: ub.position,
          select: {b, ub.position}
      )

  def earned_count(user_id),
    do: Repo.aggregate(from(ub in UserBadge, where: ub.user_id == ^user_id), :count)

  def total, do: Repo.aggregate(Badge, :count)

  @doc "Remplace les badges équipés par `badge_ids`, dans l'ordre et 3 au plus."
  def equip(user_id, badge_ids) do
    with {:ok, ids} <- cast_ids(badge_ids) do
      Repo.transact(fn ->
        # Sérialise les modifications d'un même utilisateur ; relâché à la fin de la transaction.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "user_badges:" <> user_id
        ])

        owned = from(ub in UserBadge, where: ub.user_id == ^user_id)

        if Repo.aggregate(where(owned, [ub], ub.badge_id in ^ids), :count) == length(ids) do
          Repo.update_all(where(owned, [ub], ub.equipped), set: [equipped: false, position: nil])

          for {id, position} <- Enum.with_index(ids, 1) do
            Repo.update_all(where(owned, [ub], ub.badge_id == ^id),
              set: [equipped: true, position: position]
            )
          end

          {:ok, ids}
        else
          {:error, :badge_not_earned}
        end
      end)
    end
  end

  defp cast_ids(ids) when is_list(ids) do
    casted = Enum.map(ids, &MlLearning.cast_uuid/1)

    cond do
      :error in casted or length(Enum.uniq(casted)) != length(casted) -> invalid_ids()
      length(casted) > @max_equipped -> {:error, :equip_limit_exceeded}
      true -> {:ok, for({:ok, id} <- casted, do: id)}
    end
  end

  defp cast_ids(_), do: invalid_ids()

  defp invalid_ids,
    do: {:error, {:invalid, %{badge_ids: ["must be a list of distinct badge ids"]}}}

  # Valeurs réelles des critères (4 requêtes indexées par utilisateur).
  defp metrics(user_id, today) do
    lessons =
      Repo.all(
        from p in LessonProgress,
          join: l in assoc(p, :lesson),
          where: p.user_id == ^user_id and p.status == "completed",
          select: l.title
      )

    Map.merge(Progress.xp_stats(user_id, today), %{
      lessons: lessons,
      adventures: Progress.adventures_completed(user_id),
      multiplayer_wins:
        Repo.aggregate(
          from(e in XpEvent, where: e.user_id == ^user_id and like(e.ref_key, "multiplayer:%")),
          :count
        )
    })
  end

  defp current(%Badge{criterion: "lessons_completed"}, m), do: length(m.lessons)

  defp current(%Badge{criterion: "lesson_completed", param: title}, m),
    do: if(title in m.lessons, do: 1, else: 0)

  defp current(%Badge{criterion: "adventures_completed"}, m), do: m.adventures
  defp current(%Badge{criterion: "total_xp"}, m), do: m.xp
  defp current(%Badge{criterion: "level"}, m), do: m.level
  defp current(%Badge{criterion: "streak_days"}, m), do: m.streak
  defp current(%Badge{criterion: "multiplayer_wins"}, m), do: m.multiplayer_wins
end
