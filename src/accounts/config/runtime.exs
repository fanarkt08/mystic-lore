import Config

# Lu au démarrage dans tous les environnements, releases comprises (PHX_SERVER=true bin/accounts start).
if System.get_env("PHX_SERVER") do
  config :accounts, MlAccountsWeb.Endpoint, server: true
end

config :accounts, MlAccountsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4001"))]

# Liens envoyés par e-mail : ils pointent vers le service web (seul exposé au navigateur).
config :accounts,
  web_url: String.trim_trailing(System.get_env("WEB_URL", "http://localhost:4000"), "/"),
  mail_from: {"MysticLore", System.get_env("MAIL_FROM", "no-reply@mysticlore.test")},
  # clé dédiée au chiffrement des secrets TOTP (32 octets au moins), sinon dérivée de INTERNAL_SECRET
  totp_encryption_key: System.get_env("TOTP_ENCRYPTION_KEY"),
  # délai de grâce avant l'exécution d'une suppression de compte demandée (jours, ≥ 0)
  deletion_grace_days: String.to_integer(System.get_env("ACCOUNT_DELETION_GRACE_DAYS", "30")),
  # demandes de support : supprimées ce nombre de jours après leur clôture (purge quotidienne)
  support_retention_days: String.to_integer(System.get_env("SUPPORT_RETENTION_DAYS", "180"))

# Dossier privé des avatars ; un chemin relatif est refusé pour ne jamais écrire dans le répertoire courant.
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

if dir = storage_dir.("ACCOUNTS_STORAGE_DIR"), do: config(:accounts, storage_dir: dir)

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :accounts, MlAccounts.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Avatars : un volume persistant est obligatoire (un dossier temporaire perdrait les images au redémarrage).
  storage_dir.("ACCOUNTS_STORAGE_DIR") ||
    raise """
    environment variable ACCOUNTS_STORAGE_DIR is missing or empty.
    Set it to the absolute path of a persistent, private directory for uploaded avatars (for example /data/accounts).
    """

  config :accounts, MlAccountsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  # E-mails : configurer ici un vrai adaptateur Swoosh (Mailgun, SMTP…).
end
