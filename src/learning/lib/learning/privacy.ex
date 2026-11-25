defmodule MlLearning.Privacy do
  @moduledoc """
  Export et suppression des données d'un membre dans learning.
  Les aventures qu'il a publiées restent au catalogue, sans auteur.
  """
  import Ecto.Query
  alias MlLearning.{Progress, Repo}
  alias MlLearning.Catalog.{Adventure, Chapter}
  alias MlLearning.Gamification.UserBadge
  alias MlLearning.Offline.Action
  alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}

  def export(user_id) do
    %{xp: xp, level: level, streak: streak} = Progress.xp_stats(user_id)

    %{
      "xp_total" => xp,
      "level" => level,
      "streak_days" => streak,
      "enrollments" =>
        Repo.all(
          from e in Enrollment,
            join: a in assoc(e, :adventure),
            left_join: l in assoc(e, :last_lesson),
            where: e.user_id == ^user_id,
            order_by: [e.inserted_at, e.id],
            select: %{
              "adventure" => a.slug,
              "title" => a.title,
              "enrolled_at" => e.inserted_at,
              "last_lesson" => l.title,
              "completed_at" => e.completed_at
            }
        ),
      "lesson_progress" =>
        Repo.all(
          from p in LessonProgress,
            join: l in assoc(p, :lesson),
            join: c in Chapter,
            on: c.id == l.chapter_id,
            join: a in Adventure,
            on: a.id == c.adventure_id,
            where: p.user_id == ^user_id,
            order_by: [p.inserted_at, p.id],
            select: %{
              "adventure" => a.slug,
              "lesson_id" => l.id,
              "lesson" => l.title,
              "status" => p.status,
              "attempts" => p.attempts,
              "notes" => p.notes,
              "draft" => p.draft,
              "completed_at" => p.completed_at,
              "updated_at" => p.updated_at
            }
        ),
      "xp_events" =>
        Repo.all(
          from x in XpEvent,
            where: x.user_id == ^user_id,
            order_by: [x.inserted_at, x.id],
            select: %{
              "ref_key" => x.ref_key,
              "amount" => x.amount,
              "inserted_at" => x.inserted_at
            }
        ),
      "badges" =>
        Repo.all(
          from ub in UserBadge,
            join: b in assoc(ub, :badge),
            where: ub.user_id == ^user_id,
            order_by: [ub.earned_at, b.position],
            select: %{
              "badge" => b.slug,
              "name" => b.name,
              "earned_at" => ub.earned_at,
              "equipped" => ub.equipped,
              "position" => ub.position
            }
        ),
      "authored_adventures" =>
        Repo.all(
          from a in Adventure,
            where: a.author_id == ^user_id,
            order_by: a.slug,
            select: %{"slug" => a.slug, "title" => a.title}
        ),
      # reçus des actions des leçons hors ligne : la réponse rendue, jamais la réponse envoyée
      "offline_actions" =>
        Repo.all(
          from a in Action,
            join: l in assoc(a, :lesson),
            where: a.user_id == ^user_id,
            order_by: [a.inserted_at, a.id],
            select: %{
              "key" => a.key,
              "lesson_id" => l.id,
              "lesson" => l.title,
              "action" => a.action,
              "result" => a.response,
              "synchronized_at" => a.inserted_at
            }
        )
    }
  end

  @doc "Supprime la progression, l'XP, les badges et les reçus du membre (idempotent)."
  def delete(user_id) do
    Repo.transact(fn ->
      for schema <- [UserBadge, XpEvent, Action, LessonProgress, Enrollment],
          do: Repo.delete_all(from x in schema, where: x.user_id == ^user_id)

      Repo.update_all(from(a in Adventure, where: a.author_id == ^user_id), set: [author_id: nil])
      {:ok, user_id}
    end)
  end
end
