defmodule MysticWeb.SecurityHeaders do
  @moduledoc """
  Browser security headers: strict CSP without inline script or style, self-hosted fonts and no framing.
  """
  import Phoenix.Controller, only: [put_secure_browser_headers: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    put_secure_browser_headers(conn, %{
      "content-security-policy" => csp(conn.host),
      "x-frame-options" => "DENY",
      "cross-origin-opener-policy" => "same-origin",
      "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=()"
    })
  end

  def csp(host) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self'",
        "font-src 'self'",
        "img-src 'self' data:",
        "connect-src 'self' ws://#{host}:* wss://#{host}:*",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'"
      ],
      "; "
    )
  end
end
