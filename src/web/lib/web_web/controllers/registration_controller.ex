defmodule MysticWeb.RegistrationController do
  @moduledoc "Sign-up form (accounts `POST /api/users`), then the « check your email » page."
  use MysticWeb, :controller
  import MysticWeb.Auth, only: [redirect_if_user: 2]
  alias MysticWeb.{Api, RateLimit}

  @fields [:email, :username, :display_name, :password]

  plug :redirect_if_user when action in [:new, :create]
  plug :put_view, html: MysticWeb.AuthHTML

  def new(conn, _params), do: render_form(conn, %{}, [], nil)

  def create(conn, %{"user" => %{} = params}) do
    attrs =
      params
      |> Map.take(Enum.map(@fields, &Atom.to_string/1))
      |> Map.new(fn {k, v} ->
        {k, if(k == "password", do: v, else: String.trim(to_string(v)))}
      end)
      |> Map.reject(fn {k, v} -> k == "display_name" and v == "" end)

    with :ok <- RateLimit.check(conn, :register),
         {:ok, %{"user" => user}} <- MlShared.Client.post(:accounts, "/api/users", json: attrs) do
      render(conn, :check_email,
        page_title: gettext("Check your email"),
        email: user["email"],
        dev_hints: Application.get_env(:web, :dev_hints, false)
      )
    else
      {:error, seconds} when is_integer(seconds) ->
        message = gettext("Too many sign-up attempts from your connection. Please wait a minute.")
        conn |> put_status(429) |> render_form(params, [], message)

      {:error, {:http, 422, _}} = error ->
        errors = Api.form_errors(error, @fields)
        message = if errors == [], do: Api.error_message(error)
        conn |> put_status(422) |> render_form(params, errors, message)

      error ->
        conn |> put_status(503) |> render_form(params, [], Api.error_message(error))
    end
  end

  def create(conn, _params), do: render_form(conn, %{}, [], nil)

  defp render_form(conn, params, errors, message) do
    params = params |> Map.take(Enum.map(@fields, &Atom.to_string/1)) |> Map.put("password", "")

    render(conn, :register,
      page_title: gettext("Create your account"),
      form: Phoenix.Component.to_form(params, as: :user, errors: errors),
      message: message
    )
  end
end
