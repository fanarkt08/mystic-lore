defmodule MysticWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :web

  # Signed and encrypted cookie that only carries the opaque session token, the locale and the socket id.
  @session_options [
    store: :cookie,
    key: "_mystic_web",
    signing_salt: "5yKqmY7N",
    encryption_salt: "Qm3vT8xL",
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:web, :secure_cookies, false),
    max_age: 30 * 24 * 60 * 60
  ]

  # `peer_data` : adresse IP du navigateur, pour la limite de débit du formulaire de contact (jamais transmise ni
  # stockée ; derrière un proxy, il faudrait la lire d'un en-tête de confiance)
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: @session_options]],
    longpoll: [connect_info: [:peer_data, session: @session_options]]

  # Lesson media (videos, posters, WebVTT captions): byte ranges for seeking come with Plug.Static; the
  # content type is set by `media_type/2` (MIME has no `.vtt`: captions must be served as text/vtt).
  plug :media_type

  plug Plug.Static,
    at: "/media/lessons",
    from: {:web, "priv/static/media/lessons"},
    gzip: false,
    content_types: false,
    headers: %{"x-content-type-options" => "nosniff", "cache-control" => "public, max-age=86400"}

  plug Plug.Static,
    at: "/",
    from: :web,
    gzip: not code_reloading?,
    only: MysticWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId

  # Les chemins porteurs d'un jeton (confirmation, réinitialisation, changement d'e-mail) ne sont jamais journalisés.
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MysticWeb.Router

  @doc false
  def media_type(%Plug.Conn{path_info: ["media", "lessons" | _]} = conn, _opts) do
    case Path.extname(conn.request_path) do
      ".vtt" -> put_resp_content_type(conn, "text/vtt")
      ext -> put_resp_content_type(conn, MIME.type(String.trim_leading(ext, ".")), nil)
    end
  end

  def media_type(conn, _opts), do: conn

  @doc false
  def log_level(%Plug.Conn{path_info: [p | _]}) when p in ["confirm", "reset-password"], do: false
  def log_level(%Plug.Conn{path_info: ["settings", "confirm-email" | _]}), do: false
  def log_level(_conn), do: :info
end
