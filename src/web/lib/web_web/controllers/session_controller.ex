defmodule MysticWeb.SessionController do
  @moduledoc """
  Form login, its 2FA step and logout. The sign-in challenge stays in the signed session, never in a URL.
  """
  use MysticWeb, :controller
  import MysticWeb.Auth, only: [redirect_if_user: 2]
  alias MysticWeb.{Auth, RateLimit}

  @challenge "two_factor_challenge"
  @return_to "user_return_to"

  plug :redirect_if_user when action in [:new, :create, :two_factor, :create_two_factor]
  plug :put_view, html: MysticWeb.AuthHTML

  def new(conn, params) do
    conn =
      case Auth.return_path(params["return_to"]) do
        nil -> conn
        path -> put_session(conn, @return_to, path)
      end

    notice = if params["reason"] == "expired", do: :expired
    render_login(conn, %{}, nil, 200, notice)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password} = params})
      when is_binary(email) and is_binary(password) do
    with :ok <- RateLimit.check(conn, :login),
         {:ok, body} <-
           MlShared.Client.post(:accounts, "/api/sessions",
             json: %{email: String.trim(email), password: password},
             headers: client_headers(conn)
           ) do
      case body do
        %{"session_token" => token} when is_binary(token) ->
          logged_in(conn, token, body["user"])

        %{"two_factor_required" => true, "challenge" => challenge} when is_binary(challenge) ->
          conn |> put_session(@challenge, challenge) |> redirect(to: ~p"/login/2fa")

        _ ->
          render_login(conn, params, :unavailable, 503)
      end
    else
      {:error, seconds} when is_integer(seconds) -> render_login(conn, params, :rate_limited, 429)
      {:error, {:http, 401, _}} -> render_login(conn, params, :invalid, 401)
      {:error, {:http, 403, %{"error" => "account_deleted"}}} -> account_deleted(conn, params)
      {:error, {:http, 403, _}} -> render_login(conn, params, :unconfirmed, 403)
      {:error, {:http, 429, _}} -> render_login(conn, params, :locked, 429)
      _ -> render_login(conn, params, :unavailable, 503)
    end
  end

  def create(conn, _params), do: render_login(conn, %{}, :invalid, 400)

  @doc "Second step: only reachable with a pending challenge from a correct password."
  def two_factor(conn, _params) do
    if get_session(conn, @challenge),
      do: render_two_factor(conn, nil),
      else: redirect(conn, to: ~p"/login")
  end

  def create_two_factor(conn, params) do
    code =
      case params do
        %{"two_factor" => %{"one_time_password" => code}} when is_binary(code) ->
          String.trim(code)

        _ ->
          ""
      end

    with challenge when is_binary(challenge) <- get_session(conn, @challenge),
         :ok <- RateLimit.check(conn, :two_factor),
         {:ok, %{"session_token" => token} = body} when is_binary(token) <-
           MlShared.Client.post(:accounts, "/api/sessions/2fa",
             json: %{challenge: challenge, code: code},
             headers: client_headers(conn)
           ) do
      logged_in(conn, token, body["user"])
    else
      nil ->
        redirect(conn, to: ~p"/login")

      {:error, seconds} when is_integer(seconds) ->
        render_two_factor(conn, :rate_limited, 429)

      {:error, {:http, 401, %{"attempts_left" => left}}} when is_integer(left) and left > 0 ->
        render_two_factor(conn, {:invalid, left}, 401)

      {:error, {:http, 401, _}} ->
        start_over(conn, gettext("Too many incorrect codes. Please log in again."))

      {:error, {:http, 404, _}} ->
        start_over(conn, gettext("Your sign-in attempt has expired. Please log in again."))

      {:error, {:http, 429, _}} ->
        message =
          gettext(
            "Too many incorrect codes for this account. Please wait 15 minutes, then log in again."
          )

        start_over(conn, message)

      _ ->
        render_two_factor(conn, :unavailable, 503)
    end
  end

  # En plus de l'effacement fait par la page (assets/js/offline.js), le serveur demande au navigateur d'effacer
  # le stockage du site : leçons hors ligne et file (IndexedDB), Cache Storage, service worker.
  def delete(conn, _params) do
    conn
    |> Auth.log_out()
    |> put_resp_header("clear-site-data", ~s("storage"))
    |> put_flash(:info, gettext("You have been logged out."))
    |> redirect(to: ~p"/")
  end

  # `Auth.log_in/2` starts a fresh cookie session: the pending challenge (and the page to come back to, read just
  # before) go with the old one.
  defp logged_in(conn, token, user) do
    to = Auth.after_login_path(user, get_session(conn, @return_to))
    conn = Auth.log_in(conn, token)

    # the welcome tour greets a first login itself
    if to == ~p"/welcome",
      do: redirect(conn, to: to),
      else: conn |> put_flash(:info, gettext("Welcome back!")) |> redirect(to: to)
  end

  # Deletion due (in progress): the password was right, but the account can no longer be used.
  defp account_deleted(conn, params) do
    conn
    |> put_flash(:error, gettext("This account is being deleted and can no longer be used."))
    |> render_login(params, nil, 403)
  end

  defp start_over(conn, message) do
    conn |> delete_session(@challenge) |> put_flash(:error, message) |> redirect(to: ~p"/login")
  end

  # Printable ASCII only (user agents are ASCII; header values must stay valid), 512 bytes at most.
  defp client_headers(conn) do
    user_agent =
      conn
      |> get_req_header("user-agent")
      |> List.first("")
      |> String.replace(~r/[^\x20-\x7E]/, "")
      |> binary_slice(0, 512)

    [
      {"x-client-ua", user_agent},
      {"x-client-ip", conn.remote_ip |> :inet.ntoa() |> to_string()}
    ]
  end

  defp render_login(conn, params, error, status, notice \\ nil) do
    conn
    |> put_status(status)
    |> render(:login,
      page_title: gettext("Log in"),
      notice: notice,
      return_to?: get_session(conn, @return_to) != nil,
      form:
        Phoenix.Component.to_form(%{"email" => params["email"] || "", "password" => ""},
          as: :user
        ),
      error: error,
      dev_hints: Application.get_env(:web, :dev_hints, false)
    )
  end

  defp render_two_factor(conn, error, status \\ 200) do
    conn
    |> put_status(status)
    |> render(:two_factor,
      page_title: gettext("Two-factor authentication"),
      form: Phoenix.Component.to_form(%{"one_time_password" => ""}, as: :two_factor),
      error: error
    )
  end
end
