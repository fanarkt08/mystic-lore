import Config

# Avec une release : PHX_SERVER=true bin/social start
if System.get_env("PHX_SERVER") do
  config :social, MlSocialWeb.Endpoint, server: true
end

config :social, MlSocialWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4004"))]

# (une variable vide ou blanche, comme dans .env.example, vaut une variable absente)
env = fn name -> if (value = String.trim(System.get_env(name) || "")) != "", do: value end

# Dossier privé des pièces jointes ; un chemin relatif est refusé pour ne jamais écrire dans le répertoire courant.
storage_dir = fn name ->
  with dir when is_binary(dir) <- env.(name) do
    unless Path.type(dir) == :absolute,
      do:
        raise(
          "environment variable #{name} must be an absolute path (got #{inspect(dir)}): uploaded files are never written to the current directory"
        )

    dir
  end
end

if dir = storage_dir.("SOCIAL_STORAGE_DIR"), do: config(:social, storage_dir: dir)

# Antivirus clamd facultatif : sans CLAMD_HOST, les pièces jointes sont acceptées avec le statut `unscanned`.
if host = env.("CLAMD_HOST") do
  config :social,
    scanner:
      {MlSocial.Scanner.Clamd,
       host: host,
       port: String.to_integer(env.("CLAMD_PORT") || "3310"),
       timeout: String.to_integer(env.("CLAMD_TIMEOUT_MS") || "10000")}
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing (ecto://USER:PASS@HOST/DATABASE)"

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :social, MlSocial.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (mix phx.gen.secret)"

  # Pièces jointes : un volume persistant est obligatoire (un dossier temporaire perdrait les fichiers au redémarrage).
  storage_dir.("SOCIAL_STORAGE_DIR") ||
    raise """
    environment variable SOCIAL_STORAGE_DIR is missing or empty.
    Set it to the absolute path of a persistent, private directory for message attachments (for example /data/social).
    """

  config :social, MlSocialWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
