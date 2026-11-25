defmodule MlCommunityWeb.DiscussionController do
  use MlCommunityWeb, :controller
  alias MlCommunity.{Accounts, Forum, Posts, Viewer, Votes}
  alias MlCommunityWeb.Json

  action_fallback MlCommunityWeb.FallbackController

  def categories(conn, _params) do
    me = conn.assigns.user_id
    viewer = %Viewer{id: me, staff: Viewer.staff?(me)}
    json(conn, %{categories: Enum.map(Forum.categories(), &Json.category(&1, viewer))})
  end

  def index(conn, params) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id) do
      page = Forum.list_discussions(viewer, params)
      users = Accounts.users(Enum.map(page.entries, & &1.author_id))
      json(conn, %{page | entries: Enum.map(page.entries, &Json.summary(&1, users))})
    end
  end

  def show(conn, %{"slug" => slug} = params) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, discussion} <- Forum.fetch_discussion(viewer, slug) do
      replies = Forum.list_replies(viewer, discussion, params["page"])
      users = Accounts.users([discussion.author_id | Enum.map(replies.entries, & &1.author_id)])

      json(conn, %{
        discussion: Json.discussion(discussion, viewer, users),
        replies: %{
          replies
          | entries: Enum.map(replies.entries, &Json.reply(&1, discussion, viewer, users))
        }
      })
    end
  end

  def create(conn, params) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, discussion} <- Posts.create_discussion(viewer, params) do
      conn |> put_status(:created) |> render_discussion(viewer, discussion.slug)
    end
  end

  def update(conn, %{"slug" => slug} = params) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, _discussion} <- Posts.update_discussion(viewer, slug, params) do
      render_discussion(conn, viewer, slug)
    end
  end

  def delete(conn, %{"slug" => slug}) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         :ok <- Posts.delete_discussion(viewer, slug),
         do: send_resp(conn, 204, "")
  end

  def follow(conn, %{"slug" => slug}) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         :ok <- Posts.follow(viewer, slug),
         do: json(conn, %{following: true})
  end

  def unfollow(conn, %{"slug" => slug}) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         :ok <- Posts.unfollow(viewer, slug),
         do: json(conn, %{following: false})
  end

  def vote(conn, %{"slug" => slug}), do: set_vote(conn, slug, true)
  def unvote(conn, %{"slug" => slug}), do: set_vote(conn, slug, false)

  defp set_vote(conn, slug, on?) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, discussion} <- Forum.fetch_discussion(viewer, slug),
         {:ok, vote} <- Votes.set(viewer, discussion, on?),
         do: json(conn, vote)
  end

  # Sans `reply_id` : 422 (seul DELETE retire la solution).
  def set_solution(conn, %{"slug" => slug} = params),
    do: solution(conn, slug, params["reply_id"] || "")

  def clear_solution(conn, %{"slug" => slug}), do: solution(conn, slug, nil)

  defp solution(conn, slug, reply_id) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, discussion} <- Posts.set_solution(viewer, slug, reply_id),
         do: json(conn, %{solution_reply_id: discussion.solution_reply_id})
  end

  defp render_discussion(conn, viewer, slug) do
    {:ok, discussion} = Forum.fetch_discussion(viewer, slug)
    users = Accounts.users([discussion.author_id])
    json(conn, %{discussion: Json.discussion(discussion, viewer, users)})
  end
end
