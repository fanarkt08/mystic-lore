import Config

# PHX_SERVER=true bin/learning start (release)
if System.get_env("PHX_SERVER") do
  config :learning, MlLearningWeb.Endpoint, server: true
end

config :learning, MlLearningWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4002"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing (ecto://USER:PASS@HOST/DATABASE)"

  System.get_env("INTERNAL_SECRET") ||
    raise "environment variable INTERNAL_SECRET is missing (shared service-to-service secret)"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :learning, MlLearning.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (mix phx.gen.secret)"

  config :learning, MlLearningWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
