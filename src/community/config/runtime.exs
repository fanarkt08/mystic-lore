import Config

# Avec une release : PHX_SERVER=true bin/community start
if System.get_env("PHX_SERVER") do
  config :community, MlCommunityWeb.Endpoint, server: true
end

config :community, MlCommunityWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4006"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing (ecto://USER:PASS@HOST/DATABASE)"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :community, MlCommunity.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (mix phx.gen.secret)"

  config :community, MlCommunityWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
