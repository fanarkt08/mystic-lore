defmodule MlCommunityWeb.ReplyController do
  use MlCommunityWeb, :controller
  alias MlCommunity.{Accounts, Forum, Posts, Viewer, Votes}
  alias MlCommunityWeb.Json

  action_fallback MlCommunityWeb.FallbackController

  def create(conn, %{"slug" => slug} = params) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, reply} <- Posts.create_reply(viewer, slug, params) do
      conn |> put_status(:created) |> render_reply(viewer, reply)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, reply} <- Posts.update_reply(viewer, id, params),
         do: render_reply(conn, viewer, reply)
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         :ok <- Posts.delete_reply(viewer, id),
         do: send_resp(conn, 204, "")
  end

  def vote(conn, %{"id" => id}), do: set_vote(conn, id, true)
  def unvote(conn, %{"id" => id}), do: set_vote(conn, id, false)

  defp set_vote(conn, id, on?) do
    with {:ok, viewer} <- Viewer.resolve(conn.assigns.user_id),
         {:ok, reply} <- Forum.fetch_reply(viewer, id),
         {:ok, vote} <- Votes.set(viewer, reply, on?),
         do: json(conn, vote)
  end

  defp render_reply(conn, viewer, reply) do
    users = Accounts.users([reply.author_id])
    json(conn, %{reply: Json.reply(reply, reply.discussion, viewer, users)})
  end
end
