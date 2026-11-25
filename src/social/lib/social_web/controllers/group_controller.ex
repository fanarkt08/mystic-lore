defmodule MlSocialWeb.GroupController do
  @moduledoc "Groupes (`MlSocial.Groups`) : création, renommage, ajout, retrait et départ ; réponse = le groupe."
  use MlSocialWeb, :controller
  alias MlSocial.Groups
  alias MlSocialWeb.ConversationController

  action_fallback MlSocialWeb.FallbackController

  def create(conn, params) do
    with {:ok, summary} <- Groups.create(conn.assigns.user_id, params),
         do: conn |> put_status(:created) |> ConversationController.show_one(summary)
  end

  def rename(conn, %{"id" => id} = params) do
    with {:ok, summary} <- Groups.rename(conn.assigns.user_id, id, params),
         do: ConversationController.show_one(conn, summary)
  end

  def add_member(conn, %{"id" => id} = params) do
    with {:ok, summary} <- Groups.add_member(conn.assigns.user_id, id, params["user_id"]),
         do: ConversationController.show_one(conn, summary)
  end

  def remove_member(conn, %{"id" => id, "user_id" => user_id}) do
    with {:ok, summary} <- Groups.remove_member(conn.assigns.user_id, id, user_id),
         do: ConversationController.show_one(conn, summary)
  end

  def leave(conn, %{"id" => id}) do
    with :ok <- Groups.leave(conn.assigns.user_id, id), do: send_resp(conn, 204, "")
  end
end
