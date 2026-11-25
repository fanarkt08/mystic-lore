defmodule MysticWeb.CommunityFixtures do
  @moduledoc "Fictional community payloads."

  def author(id, name),
    do: %{"id" => id, "username" => String.downcase(name), "display_name" => name, "bio" => ""}

  def categories do
    %{
      "categories" => [
        category("announcements", "Announcements", staff_only: true, can_post: false),
        category("help-questions", "Help & Questions"),
        category("off-topic", "Off-topic")
      ]
    }
  end

  defp category(slug, name, opts \\ []) do
    %{
      "slug" => slug,
      "name" => name,
      "description" => "A fictional category.",
      "staff_only" => Keyword.get(opts, :staff_only, false),
      "can_post" => Keyword.get(opts, :can_post, true)
    }
  end

  def discussion(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "d-1",
        "slug" => "why-does-range-3-stop-at-2-abcd2345",
        "title" => "Why does range(3) stop at 2?",
        "excerpt" => "The grove waters saplings 0, 1 and 2.",
        "body" => "The grove waters saplings 0, 1 and 2.",
        "category" => %{"slug" => "help-questions", "name" => "Help & Questions"},
        "author" => author("author-1", "Hugo Bernard"),
        "status" => "visible",
        "pinned" => false,
        "locked" => false,
        "solved" => false,
        "helpful_count" => 2,
        "reply_count" => 1,
        "following" => false,
        "voted" => false,
        "can_edit" => false,
        "edited_at" => nil,
        "solution_reply_id" => nil,
        "moderation_reason" => nil,
        "last_activity_at" => "2026-11-23T09:30:00Z",
        "inserted_at" => "2026-11-23T09:00:00Z"
      },
      attrs
    )
  end

  def reply(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "r-1",
        "discussion_id" => "d-1",
        "body" => "It starts counting at zero, like the forest spirits.",
        "author" => author("author-2", "Inès Petit"),
        "status" => "visible",
        "helpful_count" => 1,
        "voted" => false,
        "solution" => false,
        "can_edit" => false,
        "moderation_reason" => nil,
        "edited_at" => nil,
        "inserted_at" => "2026-11-23T09:30:00Z"
      },
      attrs
    )
  end

  @doc "`GET /api/discussions/:slug` response."
  def thread(discussion, replies, attrs \\ %{}) do
    %{
      "discussion" => discussion,
      "replies" =>
        Map.merge(
          %{"entries" => replies, "page" => 1, "total_pages" => 1, "total" => length(replies)},
          attrs
        )
    }
  end
end
