defmodule MlCommunity.Privacy do
  @moduledoc """
  Export et suppression des données d'un membre dans community ; ses contributions restent, sans auteur.
  """
  import Ecto.Query
  alias MlCommunity.{Discussion, Follow, ModerationEntry, Reply, Report, Repo, Vote}

  def export(me) do
    %{
      "discussions" =>
        Repo.all(
          from d in Discussion,
            where: d.author_id == ^me,
            order_by: [d.inserted_at, d.id],
            select: %{
              "id" => d.id,
              "slug" => d.slug,
              "category" => d.category,
              "title" => d.title,
              "body" => d.body,
              "status" => d.status,
              "moderation_reason" => d.moderation_reason,
              "inserted_at" => d.inserted_at,
              "edited_at" => d.edited_at
            }
        ),
      "replies" =>
        Repo.all(
          from r in Reply,
            join: d in assoc(r, :discussion),
            where: r.author_id == ^me,
            order_by: [r.inserted_at, r.id],
            select: %{
              "id" => r.id,
              "discussion" => d.slug,
              "body" => r.body,
              "status" => r.status,
              "moderation_reason" => r.moderation_reason,
              "inserted_at" => r.inserted_at,
              "edited_at" => r.edited_at
            }
        ),
      "votes" =>
        Repo.all(
          from v in Vote,
            where: v.user_id == ^me,
            order_by: [v.inserted_at, v.target_id],
            select: %{
              "target_type" => v.target_type,
              "target_id" => v.target_id,
              "inserted_at" => v.inserted_at
            }
        ),
      "follows" =>
        Repo.all(
          from f in Follow,
            join: d in Discussion,
            on: d.id == f.discussion_id,
            where: f.user_id == ^me,
            order_by: [f.inserted_at, d.slug],
            select: %{"discussion" => d.slug, "inserted_at" => f.inserted_at}
        ),
      "reports_filed" =>
        Repo.all(
          from r in Report,
            where: r.reporter_id == ^me,
            order_by: [r.inserted_at, r.id],
            select: %{
              "target_type" => r.target_type,
              "target_id" => r.target_id,
              "reason" => r.reason,
              "details" => r.details,
              "status" => r.status,
              "inserted_at" => r.inserted_at
            }
        ),
      "moderation_actions" =>
        Repo.all(
          from m in ModerationEntry,
            where: m.moderator_id == ^me,
            order_by: [m.inserted_at, m.id],
            select: %{
              "action" => m.action,
              "target_type" => m.target_type,
              "target_id" => m.target_id,
              "reason" => m.reason,
              "inserted_at" => m.inserted_at
            }
        )
    }
  end

  @doc "Supprime les abonnements du membre et garde ses contributions (idempotent)."
  def delete(me) do
    Repo.delete_all(from f in Follow, where: f.user_id == ^me)
    :ok
  end
end
