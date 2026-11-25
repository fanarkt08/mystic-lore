# accounts (MlAccounts) : port 4001

Comptes MysticLore : inscription, confirmation d'e-mail, sessions opaques, verrouillage des connexions,
profils publics, et sécurité des comptes : mot de passe oublié, authentification à deux facteurs TOTP
(codes de récupération), sessions actives révocables (événement `{:sessions_revoked, user_id}` sur
`"user:<id>"`), limite sur le mot de passe actuel, changement d'e-mail vérifié.
Profil enrichi et préférences : pronoms, centres d'intérêt, couverture, avatar (blason ou image nettoyée de
ses métadonnées, `MlAccounts.Avatars`), visibilité filtrée ici (`MlAccounts.Profiles`), préférences validées
(`MlAccounts.Preferences` ; thème VIP vérifié chez billing).
Centre de notifications : producteur des catégories `security` et `account` (`MlAccounts.Notify`, Oban,
file `notify`) et envoi des e-mails demandés par le centre (`POST /api/internal/users/:id/notification-email`,
`MlAccounts.NotificationEmail` : modèles en liste blanche en / fr, aucun contenu privé).
Demandes du formulaire de contact (`MlAccounts.Support` : visiteurs et membres, limites par compte et par
adresse cible, accusé de réception sans le texte soumis, file du staff auditée, réponse par e-mail, rétention par
`MlAccounts.Support.PurgeWorker`) et état de l'accueil guidé (`onboarding`, `PUT /api/me/onboarding`).
API JSON interne (jeton `MlShared.Plug.Internal` sur `/api/*`), contrats : `docs/CONTRACTS.md`,
`docs/contracts/accounts-security.md`, `docs/contracts/accounts-profile.md`, `docs/contracts/notifications.md` et
`docs/contracts/support.md`.

    mix setup          # dépendances, base ml_accounts_dev, migrations, membres de démo (seeds idempotents)
    mix phx.server     # http://localhost:4001 : GET /healthz ; e-mails en dev : http://localhost:4001/dev/mailbox
    mix test

Modules : `MlAccounts` (contexte), `MlAccounts.TwoFactor` (TOTP, codes de récupération, chiffrement du secret),
`MlAccounts.Throttle` (limites à fenêtre glissante en base). Dépendances ajoutées : `nimble_totp` (codes TOTP),
`eqrcode` (QR code SVG), `tz` (validation des fuseaux IANA, base embarquée sans accès réseau).

Variables : `PORT` (4001), `WEB_URL` (liens des e-mails, défaut http://localhost:4000), `MAIL_FROM`,
`INTERNAL_SECRET` (obligatoire hors dev/test), `TOTP_ENCRYPTION_KEY` (facultative, ≥ 32 octets : clé dédiée au
chiffrement des secrets TOTP ; à défaut dérivée de `INTERNAL_SECRET` : la changer rend les secrets illisibles,
les membres passent alors par un code de récupération), `DB_USER` / `DB_PASSWORD` / `DB_HOST` / `DB_NAME` (dev),
`DATABASE_URL` + `SECRET_KEY_BASE` (prod), `SEED_DEMO_PASSWORD` (seeds), `ACCOUNTS_STORAGE_DIR` (dossier privé des
avatars, chemin absolu ; vide = défaut `priv/storage` en dev ; obligatoire en prod, sinon refus de démarrer), `SUPPORT_RETENTION_DAYS` (demandes de support
supprimées ce nombre de jours après leur clôture, défaut 180).

Journaux : mots de passe, jetons, codes et challenges filtrés des paramètres ; les chemins
`/api/password-resets/<jeton>` ne sont pas journalisés.
