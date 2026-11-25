import Config

# Release: PHX_SERVER=true bin/studio start
if System.get_env("PHX_SERVER") do
  config :studio, MlStudioWeb.Endpoint, server: true
end

config :studio, MlStudioWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4007"))]

# Private storage of images and media; a relative path is refused so nothing lands in the current directory.
storage_dir = fn name ->
  case String.trim(System.get_env(name) || "") do
    "" ->
      nil

    dir ->
      unless Path.type(dir) == :absolute,
        do:
          raise(
            "environment variable #{name} must be an absolute path (got #{inspect(dir)}): uploaded files are never written to the current directory"
          )

      dir
  end
end

# AI provider and storage are set explicitly in tests instead of read from the developer's shell.
if config_env() != :test do
  config :studio, ai_provider: System.get_env("AI_PROVIDER")

  config :studio, :anthropic,
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    model: System.get_env("AI_MODEL") || "claude-fable-5-2",
    effort: System.get_env("AI_EFFORT") || "high",
    max_tokens: 16_000,
    receive_timeout: String.to_integer(System.get_env("AI_TIMEOUT_MS") || "300000")

  if dir = storage_dir.("STUDIO_STORAGE_DIR"), do: config(:studio, storage_dir: dir)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing (ecto://USER:PASS@HOST/DATABASE)"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :studio, MlStudio.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (mix phx.gen.secret)"

  # Images and media: a persistent private volume is required (a temporary directory would lose them on restart).
  storage_dir.("STUDIO_STORAGE_DIR") ||
    raise """
    environment variable STUDIO_STORAGE_DIR is missing or empty.
    Set it to the absolute path of a persistent, private directory for studio images and media (for example /data/studio).
    """

  config :studio, MlStudioWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "example.com", port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
