import Config

# Avec une release : PHX_SERVER=true bin/notifications start
if System.get_env("PHX_SERVER") do
  config :notifications, MlNotificationsWeb.Endpoint, server: true
end

config :notifications, MlNotificationsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4008"))]

# (une variable vide, comme dans .env.example, vaut une variable absente)
env = fn name -> if (value = System.get_env(name)) not in [nil, ""], do: value end

# Délai avant l'envoi d'un e-mail facultatif (secondes) : annulé si la notification est lue entre-temps.
if config_env() != :test do
  if delay = env.("NOTIFICATIONS_EMAIL_DELAY_S"),
    do: config(:notifications, email_delay_seconds: String.to_integer(delay))
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing (ecto://USER:PASS@HOST/DATABASE)"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :notifications, MlNotifications.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (mix phx.gen.secret)"

  config :notifications, MlNotificationsWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
