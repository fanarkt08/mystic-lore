defmodule MysticWeb.OfflineController do
  @moduledoc "Service worker, web app manifest, offline page and JSON routes for offline reading."
  use MysticWeb, :controller
  alias MysticWeb.{Auth, Format, Offline, Preferences}

  @worker_path Path.expand("../../../assets/js/service_worker.js", __DIR__)
  @external_resource @worker_path
  @worker File.read!(@worker_path)

  @static ~w(/assets/css/app.css /assets/js/app.js /favicon.ico
             /icons/icon-192.png /icons/icon-512.png /icons/icon-maskable-512.png)
  @fonts Path.expand("../../../priv/static/fonts", __DIR__)
         |> File.ls!()
         |> Enum.filter(&String.ends_with?(&1, ".woff2"))
         |> Enum.sort()
         |> Enum.map(&"/fonts/#{&1}")

  @doc "Paths cached when the worker installs: static files (digested in production) and the offline page."
  def precache, do: Enum.map(@static ++ @fonts, &MysticWeb.Endpoint.static_path/1) ++ ["/offline"]

  def service_worker(conn, _params) do
    precache = precache()

    version =
      :crypto.hash(:sha256, [@worker | precache])
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    header = """
    const VERSION = #{Jason.encode!(version)}
    const SHELL = "/offline"
    const PRECACHE = #{Jason.encode!(precache)}
    """

    conn
    |> put_resp_content_type("text/javascript")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'self'")
    |> send_resp(200, header <> @worker)
  end

  def manifest(conn, _params) do
    conn = fetch_cookies(conn)
    Gettext.put_locale(MysticWeb.Gettext, locale(conn))
    icon = &MysticWeb.Endpoint.static_path/1

    manifest = %{
      name: "MysticLore",
      short_name: "MysticLore",
      description:
        gettext("An enchanted academy where every lesson is a chapter of your own adventure."),
      lang: Gettext.get_locale(MysticWeb.Gettext),
      id: "/",
      start_url: "/dashboard",
      scope: "/",
      display: "standalone",
      background_color: "#090E20",
      theme_color: "#090E20",
      icons: [
        %{src: icon.("/icons/icon-192.png"), sizes: "192x192", type: "image/png", purpose: "any"},
        %{src: icon.("/icons/icon-512.png"), sizes: "512x512", type: "image/png", purpose: "any"},
        %{
          src: icon.("/icons/icon-maskable-512.png"),
          sizes: "512x512",
          type: "image/png",
          purpose: "maskable"
        }
      ]
    }

    conn
    |> put_resp_content_type("application/manifest+json")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, Jason.encode!(manifest))
  end

  # the manifest is fetched without the session cookie: the visitor's language choice, else the browser's
  defp locale(conn) do
    if conn.cookies[MysticWeb.Locale.cookie()] in MysticWeb.Locale.supported(),
      do: conn.cookies[MysticWeb.Locale.cookie()],
      else: conn |> get_req_header("accept-language") |> MysticWeb.Locale.from_header()
  end

  @doc "Renders the offline page, which holds nothing about the member but their display preferences."
  def shell(conn, _params) do
    prefs =
      case Auth.resolve(get_session(conn, "session_token")) do
        {:ok, user} -> Preferences.of(user)
        _ -> Preferences.of(nil)
      end

    if prefs["language"] in ~w(en fr),
      do: Gettext.put_locale(MysticWeb.Gettext, prefs["language"])

    # a VIP theme needs billing's answer: the offline page keeps the default theme then
    theme = if prefs["theme"] in Preferences.vip_themes(), do: "system", else: prefs["theme"]

    conn
    |> put_root_layout(false)
    |> put_resp_header("cache-control", "no-cache")
    |> render(:shell,
      locale: Gettext.get_locale(MysticWeb.Gettext),
      html_attrs: Preferences.html_attrs(prefs, theme),
      color_scheme: Preferences.color_scheme(theme),
      time_zone: if(Format.known_zone?(prefs["time_zone"]), do: prefs["time_zone"]),
      texts: Jason.encode!(Offline.texts(:shell))
    )
  end

  ## JSON for the browser (pipeline :offline_api)

  def session(conn, _params) do
    with {:ok, user} <- member(conn) do
      json(no_store(conn), Offline.session(user, get_csrf_token()))
    end
  end

  def package(conn, %{"lesson_id" => lesson_id}) do
    with {:ok, user} <- member(conn),
         :ok <- rate_limited(conn) do
      case Offline.package(user, lesson_id) do
        {:ok, package} -> json(no_store(conn), %{package: package})
        {:error, status, body} -> conn |> no_store() |> put_status(status) |> json(body)
      end
    end
  end

  def sync(conn, _params) do
    with {:ok, user} <- member(conn),
         :ok <- rate_limited(conn),
         {:ok, actions} <- actions(conn) do
      json(no_store(conn), Offline.sync(user, actions))
    end
  end

  # the endpoint only parses forms: the JSON body (128 KB at most) is read here
  defp actions(conn) do
    with {:ok, raw, _conn} <- read_body(conn, length: 131_072),
         {:ok, %{"actions" => actions}} when is_list(actions) <- Jason.decode(raw) do
      {:ok, actions}
    else
      _ ->
        conn
        |> put_status(400)
        |> json(%{
          error: "bad_request",
          message: gettext("Some information is invalid. Please check it and try again.")
        })
    end
  end

  defp member(conn) do
    case Auth.resolve(get_session(conn, "session_token")) do
      {:ok, user} ->
        {:ok, user}

      :anonymous ->
        conn
        |> no_store()
        |> put_status(401)
        |> json(%{
          error: "unauthorized",
          message:
            gettext(
              "Log in to synchronize: your answers stay on this device until then (they are only sent for the member who gave them)."
            )
        })

      {:error, :unavailable} ->
        conn
        |> no_store()
        |> put_status(503)
        |> json(%{error: "unavailable", message: MysticWeb.Api.error_message(:unavailable)})
    end
  end

  defp rate_limited(conn) do
    case MysticWeb.RateLimit.check(conn, :offline) do
      :ok ->
        :ok

      {:error, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(429)
        |> json(%{
          error: "rate_limited",
          message: gettext("Too many attempts. Please wait and try again.")
        })
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
