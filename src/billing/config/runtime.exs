import Config

# Release: PHX_SERVER=true bin/billing start
if System.get_env("PHX_SERVER") do
  config :billing, MlBillingWeb.Endpoint, server: true
end

config :billing, MlBillingWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4003"))]

# Payment mode (see MlBilling.mode/0); tests set it explicitly instead of reading the shell environment.
if config_env() != :test do
  config :billing, :stripe,
    secret_key: System.get_env("STRIPE_SECRET_KEY"),
    webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
    price_premium: System.get_env("STRIPE_PRICE_PREMIUM"),
    price_vip: System.get_env("STRIPE_PRICE_VIP")

  config :billing,
    local_mode: System.get_env("BILLING_LOCAL_MODE"),
    local_webhook_secret: System.get_env("BILLING_LOCAL_WEBHOOK_SECRET")
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing (ecto://USER:PASS@HOST/DATABASE)"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :billing, MlBilling.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (mix phx.gen.secret)"

  config :billing, MlBillingWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "example.com", port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
