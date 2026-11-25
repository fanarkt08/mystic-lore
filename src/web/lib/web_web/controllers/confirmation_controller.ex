defmodule MysticWeb.ConfirmationController do
  @moduledoc """
  E-mail confirmation. `GET /confirm/:token` only shows a button: the token is consumed by the POST,
  so link scanners that prefetch e-mail links can't confirm an account by themselves.
  """
  use MysticWeb, :controller
  alias MysticWeb.{Api, RateLimit}

  plug :put_view, html: MysticWeb.AuthHTML

  def show(conn, %{"token" => token}), do: render_confirm(conn, token, nil)

  def create(conn, %{"token" => token}) do
    case MlShared.Client.post(:accounts, "/api/users/confirm", json: %{token: token}) do
      {:ok, _} ->
        conn
        |> put_flash(:info, gettext("Your account is confirmed. You can now log in."))
        |> redirect(to: ~p"/login")

      {:error, {:http, 404, _}} ->
        conn |> put_status(404) |> render_confirm(nil, :invalid)

      error ->
        conn |> put_status(503) |> render_confirm(token, Api.error_message(error))
    end
  end

  @doc "Resends the confirmation e-mail (accounts always answers 204: no account enumeration)."
  def resend(conn, params) do
    email = String.trim(to_string(params["email"]))

    with :ok <- RateLimit.check(conn, :confirmation),
         {:ok, _} <-
           MlShared.Client.post(:accounts, "/api/users/resend-confirmation",
             json: %{email: email}
           ) do
      message =
        gettext(
          "If this address belongs to an unconfirmed account, a new confirmation link is on its way."
        )

      conn |> put_flash(:info, message) |> redirect(to: ~p"/login")
    else
      {:error, seconds} when is_integer(seconds) ->
        message = gettext("Too many requests from your connection. Please wait a minute.")
        conn |> put_flash(:error, message) |> redirect(to: ~p"/login")

      error ->
        conn |> put_flash(:error, Api.error_message(error)) |> redirect(to: ~p"/login")
    end
  end

  defp render_confirm(conn, token, error) do
    render(conn, :confirm,
      page_title: gettext("Confirm your account"),
      token: token,
      error: error
    )
  end
end
