defmodule MlSocialWeb.ConversationController do
  use MlSocialWeb, :controller
  alias MlSocial.{Accounts, Chat, Friends, Message}
  alias MlSocialWeb.ConversationJSON

  action_fallback MlSocialWeb.FallbackController

  def index(conn, _params) do
    me = conn.assigns.user_id
    json(conn, %{conversations: ConversationJSON.conversations(Chat.list(me), me)})
  end

  def create(conn, params) do
    with {:ok, summary} <- Chat.open(conn.assigns.user_id, params["user_id"]),
         do: show_one(conn, summary)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, summary} <- Chat.get(conn.assigns.user_id, id), do: show_one(conn, summary)
  end

  def messages(conn, %{"id" => id} = params) do
    with {:ok, page} <- Chat.messages(conn.assigns.user_id, id, params["before"]),
         do: json(conn, ConversationJSON.page(page))
  end

  # Un membre restreint par le staff n'envoie plus de message (403 `restricted` + date de fin) ; accounts
  # injoignable : refus (503), jamais d'envoi par défaut.
  def send_message(conn, %{"id" => id} = params) do
    with :ok <- Accounts.check_not_restricted(conn.assigns.user_id),
         {:ok, message} <- Chat.send_message(conn.assigns.user_id, id, params) do
      conn |> put_status(:created) |> json(%{message: Message.to_map(message)})
    end
  end

  def read(conn, %{"id" => id}) do
    with :ok <- Chat.mark_read(conn.assigns.user_id, id), do: send_resp(conn, 204, "")
  end

  def mute(conn, %{"id" => id} = params) do
    with {:ok, summary} <- Chat.mute(conn.assigns.user_id, id, params["duration"]),
         do: show_one(conn, summary)
  end

  def unmute(conn, %{"id" => id}) do
    with {:ok, summary} <- Chat.unmute(conn.assigns.user_id, id), do: show_one(conn, summary)
  end

  def unread(conn, _params) do
    me = conn.assigns.user_id
    json(conn, %{messages: Chat.unread_count(me), friend_requests: Friends.incoming_count(me)})
  end

  def show_one(conn, summary),
    do: json(conn, %{conversation: ConversationJSON.conversation(summary, conn.assigns.user_id)})
end
