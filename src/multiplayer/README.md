# MlMultiplayer : service multijoueur de MysticLore (port 4005)

Activités et salons (ouverts, privés, programmés), invitations d'amis et liens temporaires révocables, chat de salon
filtré par blocages, connexion par battements, parties coopératives « Le Relais des runes » (moteur pur, un GenServer par
partie, journal `match_events` rejouable) et récompense XP via learning. API JSON interne (jeton `MlShared.Plug.Internal`,
jamais appelée par le navigateur) : voir `docs/contracts/multiplayer.md`. Base `ml_multiplayer_dev` / `ml_multiplayer_test`.

    mix setup          # dépendances, base, migrations, seeds de démo (idempotents)
    mix phx.server     # http://localhost:4005/healthz
    mix test

Variables : `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `PORT` (4005), `ACCOUNTS_URL`, `SOCIAL_URL`, `LEARNING_URL`, `NOTIFICATIONS_URL`,
`CLUSTER_NODES` (PubSub partagé avec `web`) ; en prod `INTERNAL_SECRET`, `DATABASE_URL`, `SECRET_KEY_BASE`.
Règles (battements, grâce, abandon, balayage) : `config :multiplayer, :rules`.
