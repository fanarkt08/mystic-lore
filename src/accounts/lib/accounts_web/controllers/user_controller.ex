defmodule MlAccountsWeb.UserController do
  use MlAccountsWeb, :controller
  alias MlAccountsWeb.UserJSON

  @max_ids 100

  def create(conn, params) do
    with {:ok, user} <- MlAccounts.register(params) do
      conn |> put_status(201) |> json(%{user: UserJSON.private(user)})
    end
  end

  @doc "Rôle et état d'un membre pour les autorisations des autres services (sans e-mail)."
  def internal(conn, %{"id" => id}) do
    case MlAccounts.get_user(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      user ->
        json(conn, %{
          user:
            Map.merge(UserJSON.public(user), %{
              role: user.role,
              confirmed: not is_nil(user.confirmed_at),
              restricted_until: MlAccounts.Sanctions.restricted_until(user)
            })
        })
    end
  end

  def confirm(conn, params) do
    with {:ok, user} <- MlAccounts.confirm(params["token"]) do
      json(conn, %{user: UserJSON.private(user)})
    end
  end

  def resend_confirmation(conn, params) do
    :ok = MlAccounts.resend_confirmation(params["email"])
    send_resp(conn, 204, "")
  end

  def index(conn, params) do
    with {:ok, ids} <- parse_ids(params["ids"]) do
      json(conn, %{users: ids |> MlAccounts.list_users() |> Enum.map(&UserJSON.public/1)})
    end
  end

  def search(conn, params) do
    q = if is_binary(params["q"]), do: String.trim(params["q"]), else: ""

    if String.length(q) >= 2 do
      users = MlAccounts.search_users(q, conn.assigns.current_user)
      json(conn, %{users: Enum.map(users, &UserJSON.public/1)})
    else
      {:error, {:invalid, %{q: ["should be at least 2 character(s)"]}}}
    end
  end

  def show(conn, %{"username" => username}) do
    with %MlAccounts.User{} = user <- MlAccounts.get_user_by_username(username) do
      json(conn, %{user: UserJSON.public(user)})
    end
  end

  @doc "Profil filtré pour le lecteur du jeton interne (`sub` : membre connecté, ou aucun pour un visiteur)."
  def profile(conn, %{"username" => username}) do
    with %MlAccounts.User{} = user <- MlAccounts.get_user_by_username(username) do
      json(conn, %{profile: MlAccounts.Profiles.for_reader(user, conn.assigns.user_id)})
    end
  end

  @doc "Image d'avatar actuelle d'un compte actif (servie par web sous `/media/avatars/:name`)."
  def avatar(conn, %{"name" => name}) do
    case MlAccounts.Avatars.read(name) do
      {:ok, type, bytes} ->
        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, bytes)

      :error ->
        {:error, :not_found}
    end
  end

  defp parse_ids(nil), do: {:ok, []}

  defp parse_ids(ids) when is_binary(ids) do
    case ids |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      ids when length(ids) > @max_ids ->
        {:error, {:invalid, %{ids: ["should have at most #{@max_ids} item(s)"]}}}

      ids ->
        {:ok, ids}
    end
  end

  defp parse_ids(_), do: {:error, {:invalid, %{ids: ["is invalid"]}}}
end
