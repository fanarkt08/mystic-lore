defmodule MlCommunityWeb.Json do
  @moduledoc """
  Formes JSON du forum. Le motif de modération n'est montré qu'au staff et à l'auteur du contenu.
  """
  alias MlCommunity.{Forum, Posts}

  def category(c, viewer) do
    %{
      slug: c.slug,
      name: c.name,
      description: c.description,
      staff_only: c.staff_only,
      can_post: Forum.can_post?(c, viewer)
    }
  end

  def summary(d, users) do
    %{
      id: d.id,
      slug: d.slug,
      title: d.title,
      excerpt: excerpt(d.body),
      category: %{slug: d.category, name: d.category_name},
      author: users[d.author_id],
      status: d.status,
      pinned: d.pinned,
      locked: d.locked,
      solved: d.solution_reply_id != nil,
      helpful_count: d.helpful_count,
      reply_count: d.reply_count,
      following: d.following,
      last_activity_at: d.last_activity_at,
      inserted_at: d.inserted_at
    }
  end

  def discussion(d, viewer, users) do
    d
    |> summary(users)
    |> Map.delete(:excerpt)
    |> Map.merge(%{
      body: d.body,
      edited_at: d.edited_at,
      solution_reply_id: d.solution_reply_id,
      voted: d.voted,
      can_edit: Posts.editable(viewer, d) == :ok,
      moderation_reason: moderation_reason(d, viewer)
    })
  end

  def reply(r, discussion, viewer, users) do
    %{
      id: r.id,
      discussion_id: r.discussion_id,
      body: r.body,
      author: users[r.author_id],
      status: r.status,
      helpful_count: r.helpful_count,
      voted: r.voted,
      solution: discussion.solution_reply_id == r.id,
      can_edit: Posts.editable(viewer, r) == :ok,
      moderation_reason: moderation_reason(r, viewer),
      edited_at: r.edited_at,
      inserted_at: r.inserted_at
    }
  end

  def report(r, users) do
    snapshot = r.snapshot

    %{
      id: r.id,
      target_type: r.target_type,
      target_id: r.target_id,
      target_status: r.target_status,
      reason: r.reason,
      details: r.details,
      status: r.status,
      reporter: users[r.reporter_id],
      snapshot: %{
        title: snapshot["title"],
        body: snapshot["body"],
        author: users[snapshot["author_id"]],
        discussion_slug: snapshot["discussion_slug"],
        status: snapshot["status"],
        posted_at: snapshot["posted_at"]
      },
      resolution:
        r.resolution &&
          %{
            action: r.resolution,
            reason: r.resolution_reason,
            moderator_id: r.resolved_by,
            resolved_at: r.resolved_at
          },
      inserted_at: r.inserted_at
    }
  end

  defp moderation_reason(%{status: "visible"}, _viewer), do: nil

  defp moderation_reason(post, viewer) do
    if viewer.staff or post.author_id == viewer.id, do: post.moderation_reason
  end

  defp excerpt(body) do
    if String.length(body) > 200, do: String.slice(body, 0, 200) <> "…", else: body
  end
end
