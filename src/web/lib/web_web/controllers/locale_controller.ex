defmodule MysticWeb.LocaleController do
  @moduledoc "Stores a visitor's language choice in a cookie and goes back to the local page it came from."
  use MysticWeb, :controller
  alias MysticWeb.Locale

  @max_age 365 * 24 * 60 * 60

  def update(conn, params) do
    back = Locale.local_path(params["return_to"] || referer_path(conn))

    if params["locale"] in Locale.supported() do
      conn
      |> put_resp_cookie(Locale.cookie(), params["locale"],
        max_age: @max_age,
        same_site: "Lax",
        http_only: true,
        secure: Application.get_env(:web, :secure_cookies, false)
      )
      |> put_session("locale", params["locale"])
      |> redirect(to: back)
    else
      redirect(conn, to: back)
    end
  end

  # Pages rendered by a controller (login, sign-up…) don't send `return_to`: their own address, if same host.
  defp referer_path(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{host: host, path: path} = uri when host == conn.host and is_binary(path) <-
           URI.parse(referer) do
      if uri.query, do: "#{path}?#{uri.query}", else: path
    else
      _ -> nil
    end
  end
end
