# accounts : sécurité des comptes (complément de la section accounts de `docs/CONTRACTS.md`)

Sécurité des comptes : mot de passe oublié, 2FA TOTP, sessions actives, limite sur le
mot de passe actuel, changement d'e-mail vérifié. Toutes les routes ci-dessous exigent le jeton interne
(`MlShared.Plug.Internal`) ; « utilisateur » = jeton portant un membre existant. Les routes existantes non citées
sont inchangées.

Formes :
- Session active : `{"id","user_agent"|null,"ip"|null,"inserted_at","last_used_at","current":bool}`.
- État 2FA : `{"enabled":bool,"enabled_at":iso|null,"recovery_codes_left":int}`.

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `POST /api/sessions` (**modifié**) | service | `{email,password}` + en-têtes facultatifs `x-client-ua`, `x-client-ip` (navigateur) | 2FA inactive : inchangé (`201 {"session_token","user"}`). 2FA active : `200 {"two_factor_required":true,"challenge":"<jeton>"}` : aucune session créée. Mêmes `401 invalid_credentials` · `403 unconfirmed` · `429 locked` |
| `POST /api/sessions/2fa` | service | `{challenge, code}` (TOTP 6 chiffres OU code de récupération) + `x-client-ua`, `x-client-ip` | `201 {"session_token","user": privé}` · `401 {"error":"invalid_code","attempts_left":n}` · `404 not_found` (challenge inconnu, expiré, épuisé ou déjà utilisé) · `429 locked` |
| `POST /api/password-resets` | service | `{email}` | `204` toujours, corps vide (pas d'énumération) ; e-mail `<WEB_URL>/reset-password/<jeton>` si le compte existe |
| `GET /api/password-resets/:token` | service | | `204` lien utilisable (ne le consomme pas) · `404 not_found` |
| `POST /api/password-resets/:token` | service | `{password}` | `204` (révoque toutes les sessions) · `404 not_found` (invalide, expiré, déjà utilisé) · `422 invalid` (le lien reste utilisable) |
| `PUT /api/me/password` (**modifié**) | utilisateur | inchangé | + `429 locked` (5 échecs du mot de passe actuel / 15 min) ; révoque aussi les challenges 2FA en cours |
| `GET /api/me/sessions` | utilisateur | en-tête `x-session-token` (facultatif) | `200 {"sessions":[session active]}` (sessions valides, la plus récemment utilisée d'abord ; `current` : celle de l'en-tête) |
| `DELETE /api/me/sessions/:id` | utilisateur | `x-session-token` | `204` · `404 not_found` (pas une session du membre, id mal formé) · `409 current_session` (la session de l'en-tête : utiliser `DELETE /api/sessions/current`) |
| `DELETE /api/me/sessions` | utilisateur | `x-session-token` | `204` : révoque toutes les sessions du membre sauf celle de l'en-tête (toutes s'il est absent) |
| `POST /api/me/email` | utilisateur | `{email, password}` | `204` : lien `<WEB_URL>/settings/confirm-email/<jeton>` envoyé à la nouvelle adresse, alerte à l'ancienne · `401 invalid_credentials` · `422 invalid` (`email` : format, déjà prise, `did not change`) · `429 locked` (mot de passe) · `429 rate_limited` (3 demandes / h) |
| `POST /api/me/email/confirm` | utilisateur | `{token}` | `200 {"user": privé}` (nouvelle adresse) · `404 not_found` (invalide, expiré, utilisé, ou demandé par un autre membre) · `422 invalid` (adresse prise entre-temps) |
| `GET /api/me/2fa` | utilisateur | | `200 état 2FA` |
| `POST /api/me/2fa/setup` | utilisateur | `{password}` | `200 {"secret":"<base32>","otpauth_uri":"otpauth://totp/MysticLore:<email>?secret=…&issuer=MysticLore","qr_svg":"<svg…>"}` (secret EN attente) · `401 invalid_credentials` · `409 already_enabled` · `429 locked` |
| `POST /api/me/2fa/enable` | utilisateur | `{code}` (TOTP du secret en attente) | `200 {"recovery_codes":[10 × "xxxx-xxxx-xxxx-xxxx"]}` (en clair, une seule fois) · `401 invalid_code` · `409 already_enabled\|setup_required` · `429 locked` |
| `POST /api/me/2fa/disable` | utilisateur | `{password, code}` (TOTP ou code de récupération) | `204` (supprime secret, codes et challenges) · `401 invalid_credentials\|invalid_code` · `409 not_enabled` · `429 locked` |
| `POST /api/me/2fa/recovery-codes` | utilisateur | `{password}` | `200 {"recovery_codes":[10]}` (les anciens ne fonctionnent plus) · `401 invalid_credentials` · `409 not_enabled` · `429 locked` |

Événement : `"user:<id>"` → `{:sessions_revoked, user_id}` après `DELETE /api/sessions/current` (si une session a été
supprimée), `DELETE /api/me/sessions/:id`, `DELETE /api/me/sessions` (si au moins une), `PUT /api/me/password` et
`POST /api/password-resets/:token`. `web` revalide alors le jeton de chaque LiveView ouverte du membre et renvoie
vers `/login` celles dont la session n'est plus valide.

**Centre de notifications** ([contrat](notifications.md)) : catégorie `security`, in-app ET e-mail
verrouillés, jamais reportés pendant les heures calmes. accounts met en file (Oban `MlAccounts.NotifyWorker`, durable)
`password_changed` (paramètres ou lien de réinitialisation), `email_changed` (à la confirmation ; les e-mails de ce
changement existent déjà ici, le centre n'en envoie pas d'autre), `two_factor_enabled`, `two_factor_disabled`,
`recovery_codes_regenerated`, `sessions_revoked` (session ou autres sessions révoquées par le membre : jamais une simple
déconnexion). Les autres e-mails de sécurité sont envoyés par le centre via `POST /api/internal/users/:id/notification-email`
(modèle en liste blanche, en / fr, rappel de réinitialiser le mot de passe si ce n'était pas le membre).

## Règles (font foi)
**Jetons** (réinitialisation, changement d'e-mail, challenge) : 32 octets aléatoires en Base64url, seul le SHA-256 est
stocké (`user_tokens`, `login_challenges`), consommation sous verrou de ligne ou `UPDATE/DELETE … RETURNING`.

**Mot de passe oublié** : lien valable 1 h, à usage unique, et seulement si l'adresse du compte est toujours celle à
laquelle il a été envoyé ; l'utiliser invalide tous les autres liens du membre. 3 e-mails / h / compte (au-delà :
`204` sans e-mail). La réinitialisation révoque toutes les sessions et les challenges 2FA, lève le verrouillage des
connexions de l'adresse et confirme l'e-mail s'il ne l'était pas (le lien prouve sa réception). **La 2FA reste exigée
à la connexion.** Les chemins `/api/password-resets/<jeton>` ne sont pas journalisés.

**Mot de passe actuel** : 5 échecs / 15 min / membre (fenêtre glissante en base, `throttle_events`, verrou
consultatif : jamais dépassé en concurrence), compteur commun à `PUT /api/me/password`, `POST /api/me/email`,
`/2fa/setup`, `/2fa/disable`, `/2fa/recovery-codes` → `429 locked`, même avec le bon mot de passe ; un succès le remet
à zéro.

**TOTP** : RFC 6238 (HMAC-SHA1, 6 chiffres, 30 s). Code accepté pour le pas courant ±1, seulement s'il est
postérieur au dernier pas accepté (anti-rejeu par mise à jour conditionnelle atomique : le code qui a servi à
activer ne sert pas à se connecter). 5 codes erronés / 15 min / membre (activation, désactivation et connexion
confondues, tous challenges confondus) → `429 locked`. Secret de 20 octets chiffré au repos en AES-256-GCM (données
associées : id du membre) avec la clé HMAC-SHA256(`TOTP_ENCRYPTION_KEY` ≥ 32 octets, ou à défaut `INTERNAL_SECRET`,
`"ml-accounts:totp-secret:v1"`). Changer cette clé rend les secrets illisibles : les membres se connectent alors avec
un code de récupération puis reconfigurent la 2FA. Chaque `setup` remplace le secret en attente.

**Codes de récupération** : 10 codes de 16 caractères base32 de Crockford (80 bits), affichés `xxxx-xxxx-xxxx-xxxx`,
stockés en SHA-256(`<user_id>:<code normalisé>`) ; saisie insensible à la casse, aux espaces et aux tirets
(`i`/`l` lus `1`, `o` lu `0`) ; supprimés à l'emploi (`DELETE … RETURNING` : un seul succès en concurrence).

**Challenge de connexion** : valable 5 min, 5 essais réservés atomiquement avant la vérification ; un challenge
n'ouvre qu'une session. Supprimé par un changement / une réinitialisation du mot de passe et par la désactivation de
la 2FA.

**Sessions actives** : `user_agent` = en-tête `x-client-ua` sans octets invalides ni caractères de contrôle, 200
caractères au plus ; `ip` = en-tête `x-client-ip` anonymisé avant stockage (IPv4 → /24, dernier octet à 0 ; IPv6 →
/48 ; IPv4 encapsulée `::ffff:a.b.c.d` → IPv4 ; invalide → `null`). Les sessions expirées (30 jours) ne sont pas
listées.

**Changement d'e-mail** : mot de passe exigé (compteur commun) ; nouvelle adresse soumise aux règles de l'inscription
(normalisée, ≤ 160, unique) et différente de l'actuelle ; lien valable 24 h, à usage unique, utilisable seulement par
le membre qui l'a demandé ; une nouvelle demande remplace la précédente ; 3 demandes / h / membre. L'alerte à
l'ancienne adresse masque la nouvelle (`n•••@domaine`). À la confirmation, tous les jetons du membre sont supprimés
(les liens de réinitialisation envoyés à l'ancienne adresse ne servent plus).

## Côté web
`/login` → si `two_factor_required`, le challenge est gardé dans le cookie de session signé (jamais dans l'URL) et le
navigateur va sur `/login/2fa` (code TOTP ou de récupération ; erreur avec essais restants ; challenge expiré, épuisé
ou compte verrouillé → retour à `/login`). `/forgot-password`, `/reset-password/:token` (GET vérifie seulement, POST
consomme). Limites par IP : `login` 10/min, `two_factor` 10/min, `forgot_password` 5/min, `reset_password` 10/min.
`/settings/account` : changement d'e-mail, mot de passe (la session courante est conservée via `x-session-token`) ;
`/settings/security` : 2FA (QR
code rendu en `<img src="data:image/svg+xml;base64,…">`, secret en texte, codes de récupération affichés une fois avec
téléchargement), sessions actives avec révocation. `/settings/confirm-email/:token` (membre connecté, bouton : les
scanners de liens ne peuvent pas appliquer le changement).
