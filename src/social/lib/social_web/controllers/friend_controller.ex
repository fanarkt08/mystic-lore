defmodule MlSocialWeb.FriendController do
  use MlSocialWeb, :controller
  alias MlSocial.{Accounts, Friends, Settings}

  action_fallback MlSocialWeb.FallbackController

  # `online_visible` : cet ami laisse ses amis voir son statut en ligne (web ne montre le point que dans ce cas).
  def index(conn, _params) do
    ids = Friends.friend_ids(conn.assigns.user_id)
    users = Accounts.users(ids)
    settings = Settings.for_users(ids)

    friends =
      ids
      |> Enum.map(&Map.put(users[&1], "online_visible", settings[&1].show_online))
      |> Enum.sort_by(&sort_key/1)

    json(conn, %{friends: friends})
  end

  def requests(conn, _params) do
    {incoming, outgoing} = Friends.requests(conn.assigns.user_id)

    users =
      Accounts.users(
        Enum.map(incoming, & &1.requester_id) ++ Enum.map(outgoing, & &1.addressee_id)
      )

    json(conn, %{
      incoming: Enum.map(incoming, &%{id: &1.id, from: users[&1.requester_id]}),
      outgoing: Enum.map(outgoing, &%{id: &1.id, to: users[&1.addressee_id]})
    })
  end

  def create_request(conn, params) do
    with {:ok, friendship} <- Friends.send_request(conn.assigns.user_id, params["user_id"]) do
      conn
      |> put_status(if friendship.status == "pending", do: :created, else: :ok)
      |> json(%{id: friendship.id, status: friendship.status})
    end
  end

  def accept(conn, %{"id" => id}) do
    with {:ok, friendship} <- Friends.accept(conn.assigns.user_id, id) do
      json(conn, %{id: friendship.id, status: friendship.status})
    end
  end

  def decline(conn, %{"id" => id}) do
    with :ok <- Friends.decline(conn.assigns.user_id, id), do: send_resp(conn, 204, "")
  end

  def delete(conn, %{"user_id" => user_id}) do
    with :ok <- Friends.remove(conn.assigns.user_id, user_id), do: send_resp(conn, 204, "")
  end

  def blocks(conn, _params) do
    ids = Friends.blocked_ids(conn.assigns.user_id)
    users = Accounts.users(ids)
    json(conn, %{blocks: Enum.map(ids, &users[&1])})
  end

  def block(conn, params) do
    with :ok <- Friends.block(conn.assigns.user_id, params["user_id"]),
         do: send_resp(conn, 204, "")
  end

  def unblock(conn, %{"user_id" => user_id}) do
    with :ok <- Friends.unblock(conn.assigns.user_id, user_id), do: send_resp(conn, 204, "")
  end

  defp sort_key(user), do: String.downcase(user["display_name"] || user["username"] || user["id"])
end
