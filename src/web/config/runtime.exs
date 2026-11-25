import Config

if System.get_env("PHX_SERVER") do
  config :web, MysticWeb.Endpoint, server: true
end

config :web, MysticWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if web_url = System.get_env("WEB_URL") do
  config :web, web_url: String.trim_trailing(web_url, "/")
end

if config_env() == :dev do
  config :web, MysticWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/web_web/router\.ex$"E,
        ~r"lib/web_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (mix phx.gen.secret)"

  System.get_env("INTERNAL_SECRET") || raise "environment variable INTERNAL_SECRET is missing"
  System.get_env("WEB_URL") || raise "environment variable WEB_URL is missing (public https URL)"

  host = System.get_env("PHX_HOST") || URI.parse(System.get_env("WEB_URL")).host

  config :web, MysticWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
