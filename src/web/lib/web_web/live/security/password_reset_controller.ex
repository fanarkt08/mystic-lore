defmodule MysticWeb.Security.PasswordResetController do
  @moduledoc """
  Forgotten password pages. The answer never says whether an account exists.
  """
  use MysticWeb, :controller
  alias MysticWeb.{Api, RateLimit}

  plug :put_view, html: MysticWeb.AuthHTML

  def new(conn, _params), do: render_forgot(conn, nil, nil)

  def create(conn, params) do
    email =
      case params do
        %{"reset" => %{"email" => email}} when is_binary(email) -> String.trim(email)
        _ -> ""
      end

    with :ok <- RateLimit.check(conn, :forgot_password),
         {:ok, _} <-
           MlShared.Client.post(:accounts, "/api/password-resets", json: %{email: email}) do
      render_forgot(conn, email, nil)
    else
      {:error, seconds} when is_integer(seconds) ->
        message = gettext("Too many requests from your connection. Please wait a minute.")
        conn |> put_status(429) |> render_forgot(nil, message)

      error ->
        conn |> put_status(503) |> render_forgot(nil, Api.error_message(error))
    end
  end

  def edit(conn, %{"token" => token}) do
    case MlShared.Client.get(:accounts, api_path(token)) do
      {:error, {:http, 404, _}} -> conn |> put_status(404) |> render_reset(token, :invalid)
      # valid, or accounts unreachable: the form stays usable and the POST will tell
      _ -> render_reset(conn, token, nil)
    end
  end

  def update(conn, %{"token" => token} = params) do
    password =
      case params do
        %{"reset" => %{"password" => password}} when is_binary(password) -> password
        _ -> ""
      end

    with :ok <- RateLimit.check(conn, :reset_password),
         {:ok, _} <- MlShared.Client.post(:accounts, api_path(token), json: %{password: password}) do
      message =
        gettext("Your password has been changed and all your sessions signed out. Please log in.")

      conn |> put_flash(:info, message) |> redirect(to: ~p"/login")
    else
      {:error, seconds} when is_integer(seconds) ->
        message = gettext("Too many attempts from your connection. Please wait a minute.")
        conn |> put_status(429) |> render_reset(token, message)

      {:error, {:http, 404, _}} ->
        conn |> put_status(404) |> render_reset(token, :invalid)

      {:error, {:http, 422, _}} = error ->
        conn |> put_status(422) |> render_reset(token, nil, Api.form_errors(error, [:password]))

      error ->
        conn |> put_status(503) |> render_reset(token, Api.error_message(error))
    end
  end

  # The token is a URL path segment at accounts too: encoded so it can't reach another route.
  defp api_path(token), do: "/api/password-resets/" <> URI.encode(token, &URI.char_unreserved?/1)

  defp render_forgot(conn, sent_to, error) do
    render(conn, :forgot_password,
      page_title: gettext("Forgot your password?"),
      form: Phoenix.Component.to_form(%{"email" => ""}, as: :reset),
      sent_to: sent_to,
      error: error,
      dev_hints: Application.get_env(:web, :dev_hints, false)
    )
  end

  defp render_reset(conn, token, error, errors \\ []) do
    render(conn, :reset_password,
      page_title: gettext("Choose a new password"),
      form: Phoenix.Component.to_form(%{"password" => ""}, as: :reset, errors: errors),
      token: token,
      error: error
    )
  end
end
