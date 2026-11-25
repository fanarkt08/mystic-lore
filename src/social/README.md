# MlSocial : service social de MysticLore (port 4004)

Amis, demandes, blocages, conversations directes et de groupe, messages temps réel (livrés par membre), pièces jointes
(images nettoyées par `MlShared.Image`, PDF ; antivirus clamd optionnel), accusés de lecture, sourdine, limite de débit,
réglages de confidentialité et permissions de contact, signalements et modération.
API JSON interne (jeton `MlShared.Plug.Internal`, jamais appelée par le navigateur) : voir
[docs/contracts/social.md](../../docs/contracts/social.md). Base `ml_social_dev` / `ml_social_test`.

    mix setup          # dépendances, base, migrations, seeds de démo (idempotents)
    mix phx.server     # http://localhost:4004/healthz
    mix test

Variables : `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `PORT` (4004), `ACCOUNTS_URL` (http://localhost:4001), `NOTIFICATIONS_URL` (centre de notifications, http://localhost:4008),
`CLUSTER_NODES` (PubSub partagé), `SOCIAL_STORAGE_DIR` (pièces jointes ; défaut `priv/storage` en dev),
`CLAMD_HOST` / `CLAMD_PORT` / `CLAMD_TIMEOUT_MS` (antivirus ; sans `CLAMD_HOST`, fichiers « non analysés ») ; en prod
`INTERNAL_SECRET`, `DATABASE_URL`, `SECRET_KEY_BASE`.

Limite de débit des messages (20 / 10 s, 300 / h par membre) : compteurs ETS **par nœud**.
