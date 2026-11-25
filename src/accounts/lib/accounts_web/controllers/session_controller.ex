defmodule MlAccountsWeb.SessionController do
  @moduledoc """
  Connexion (avec second facteur si la 2FA est active), session courante, sessions actives du membre.
  `web` transmet l'appareil du navigateur dans `x-client-ua` / `x-client-ip` à la connexion.
  """
  use MlAccountsWeb, :controller
  alias MlAccountsWeb.UserJSON

  def create(conn, params) do
    case MlAccounts.login(params["email"], params["password"], client(conn)) do
      {:ok, token, user} ->
        created(conn, token, user)

      {:two_factor, challenge, _user} ->
        json(conn, %{two_factor_required: true, challenge: challenge})

      error ->
        error
    end
  end

  def create_two_factor(conn, params) do
    case MlAccounts.complete_two_factor_login(params["challenge"], params["code"], client(conn)) do
      {:ok, token, user} ->
        created(conn, token, user)

      {:error, :invalid_code, attempts_left} ->
        conn |> put_status(401) |> json(%{error: "invalid_code", attempts_left: attempts_left})

      error ->
        error
    end
  end

  def show(conn, _params) do
    case MlAccounts.get_session_user(session_token(conn)) do
      nil -> {:error, :unauthorized}
      user -> json(conn, %{user: UserJSON.private(user)})
    end
  end

  def delete(conn, _params) do
    :ok = MlAccounts.revoke_session(session_token(conn))
    send_resp(conn, 204, "")
  end

  ## Sessions actives du membre (`current` : celle de l'en-tête x-session-token)

  def index(conn, _params) do
    sessions = MlAccounts.list_sessions(conn.assigns.current_user, session_token(conn))

    json(conn, %{
      sessions:
        for {session, current} <- sessions do
          session
          |> Map.take([:id, :user_agent, :ip, :inserted_at, :last_used_at])
          |> Map.put(:current, current)
        end
    })
  end

  def revoke(conn, %{"id" => id}) do
    with :ok <- MlAccounts.revoke_user_session(conn.assigns.current_user, id, session_token(conn)),
         do: send_resp(conn, 204, "")
  end

  def revoke_others(conn, _params) do
    :ok = MlAccounts.revoke_other_sessions(conn.assigns.current_user, session_token(conn))
    send_resp(conn, 204, "")
  end

  defp created(conn, token, user),
    do: conn |> put_status(201) |> json(%{session_token: token, user: UserJSON.private(user)})

  defp client(conn),
    do: %{user_agent: header(conn, "x-client-ua"), ip: header(conn, "x-client-ip")}

  defp session_token(conn), do: header(conn, "x-session-token")

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
