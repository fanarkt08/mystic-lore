defmodule MlLearning.Gamification.Quests do
  @moduledoc """
  Quêtes quotidiennes, recalculées depuis les données réelles du jour.
  Une quête atteinte rapporte son XP une seule fois par jour, même en concurrence.
  """
  import Ecto.Query
  alias MlLearning.{Progress, Repo}
  alias MlLearning.Gamification.Quest
  alias MlLearning.Progress.{LessonProgress, XpEvent}

  @doc """
  Quêtes du jour avec récompenses dues versées : `{[%{quest, progress, completed}], quêtes récompensées par
  cet appel}`.
  """
  def settle(user_id, date \\ Date.utc_today()) do
    case Repo.all(from q in Quest, order_by: [q.position, q.slug]) do
      [] -> {[], []}
      quests -> settle(user_id, date, quests)
    end
  end

  defp settle(user_id, date, quests) do
    progress = progress(user_id, date)
    keys = Enum.map(quests, &ref_key(&1, date))

    rewarded =
      Repo.all(
        from e in XpEvent,
          where: e.user_id == ^user_id and e.ref_key in ^keys,
          select: e.ref_key
      )
      |> MapSet.new()

    results =
      for quest <- quests do
        value = min(Map.fetch!(progress, quest.kind), quest.target)
        key = ref_key(quest, date)

        cond do
          MapSet.member?(rewarded, key) ->
            {%{quest: quest, progress: quest.target, completed: true}, false}

          value >= quest.target ->
            awarded = Progress.award_xp(user_id, key, quest.xp_reward) == :awarded
            {%{quest: quest, progress: quest.target, completed: true}, awarded}

          true ->
            {%{quest: quest, progress: value, completed: false}, false}
        end
      end

    {Enum.map(results, &elem(&1, 0)), for({status, true} <- results, do: status.quest)}
  end

  @doc "Clé d'idempotence de la récompense d'une quête pour un jour."
  def ref_key(%Quest{id: id}, date), do: "quest:#{id}:#{Date.to_iso8601(date)}"

  defp progress(user_id, date) do
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.add(day_start, 86_400)

    {lessons, notes} =
      Repo.one(
        from p in LessonProgress,
          where: p.user_id == ^user_id,
          select: {
            filter(
              count(),
              p.status == "completed" and p.completed_at >= ^day_start and
                p.completed_at < ^day_end
            ),
            filter(
              count(),
              p.notes_saved_at >= ^day_start and p.notes_saved_at < ^day_end and
                fragment("btrim(?) <> ''", p.notes)
            )
          }
      )

    xp =
      Repo.one(
        from e in XpEvent,
          where:
            e.user_id == ^user_id and e.inserted_at >= ^day_start and e.inserted_at < ^day_end and
              not like(e.ref_key, "quest:%"),
          select: coalesce(sum(e.amount), 0)
      )

    %{"lessons_completed" => lessons, "xp_earned" => xp, "note_written" => notes}
  end
end
