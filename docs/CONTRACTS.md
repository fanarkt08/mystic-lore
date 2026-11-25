# MysticLore : contrats entre macroservices (source DE vérité)

> **Contrats complémentaires** (extensions, font foi pour leurs routes) :
> [learning (gamification](contracts/learning-gamification.md) · [learning) import studio](contracts/learning-import.md) ·
> [learning (formats vidéo, simulation, mini-jeu](contracts/learning-formats.md) ·
> [accounts) sécurité](contracts/accounts-security.md) · [accounts (profil et préférences](contracts/accounts-profile.md) ·
> [social) messagerie et relations complètes](contracts/social.md) (groupes, pièces jointes, accusés de lecture, sourdine,
> limite de débit, permissions de contact, livraison par membre) ·
> [multiplayer](contracts/multiplayer.md) · [community](contracts/community.md) ·
> [studio](contracts/studio.md) · [billing : crédits IA](contracts/billing-credits.md) · [données personnelles](contracts/privacy.md) ·
> [administration & modération](contracts/admin.md) (droits : [admin-permissions](admin-permissions.md)) ·
> [**centre de notifications**](contracts/notifications.md) (service `notifications`, port 4008 : catégories et
> producteurs, préférences par canal, heures calmes, e-mails par accounts, cloche et `/notifications`) ·
> [**support : formulaire de contact**](contracts/support.md) (détenu par accounts : demandes des
> visiteurs et des membres, limites par compte et par adresse cible, accusé sans le texte soumis, file `/admin/support`,
> rétention 180 jours après la clôture) · accueil guidé : `onboarding` du membre privé et `PUT /api/me/onboarding`
> ([accounts : profil](contracts/accounts-profile.md)) ·
> [**leçons hors ligne (PWA)**](contracts/offline.md) (révision des leçons, paquet
> `GET /api/lessons/:id/offline`, rejeu idempotent de `submit` / `complete` par `idempotency_key` et `revision`, routes
> web `/sw.js`, `/manifest.webmanifest`, `/offline`, `/offline/session`, `/offline/packages/:id`, `/offline/sync`)
> Routes internes communes : learning `POST /api/internal/xp`, social `GET /api/internal/relationship` et `/api/internal/blocks/:user_id`,
> accounts `GET /api/internal/users/:id`.
> L'« user public » ci-dessous est l'identité `{"id","username","display_name","avatar"}` : la bio est
> filtrée par la visibilité du profil (voir [accounts : profil et préférences](contracts/accounts-profile.md)).

Architecture : macroservices Elixir/Phoenix dans `src/` (5 à l'origine, 9), une base PostgreSQL par service (sauf web), une bibliothèque commune `src/shared` (`ml_shared`).

| Service | Dossier | Module | Port | Base | Rôle |
|---|---|---|---|---|---|
| web | `src/web` | `Mystic` / `MysticWeb` | 4000 | aucune | UI LiveView (seul service exposé au navigateur), BFF : appelle les autres services |
| accounts | `src/accounts` | `MlAccounts` / `MlAccountsWeb` | 4001 | `ml_accounts_*` | comptes, mots de passe, confirmation e-mail, sessions, profils publics |
| learning | `src/learning` | `MlLearning` / `MlLearningWeb` | 4002 | `ml_learning_*` | catalogue, leçons, inscriptions, progression, XP, tableau de bord |
| billing | `src/billing` | `MlBilling` / `MlBillingWeb` | 4003 | `ml_billing_*` | formules, abonnements, checkout (Stripe test ou simulé local), webhooks, droits |
| social | `src/social` | `MlSocial` / `MlSocialWeb` | 4004 | `ml_social_*` | amis, blocages, conversations, messages temps réel, signalements |
| multiplayer · community · studio | `src/<service>` | `MlMultiplayer` · `MlCommunity` · `MlStudio` | 4005 · 4006 · 4007 | `ml_<service>_*` | voir leurs contrats complémentaires |
| notifications | `src/notifications` | `MlNotifications` / `MlNotificationsWeb` | 4008 | `ml_notifications_*` | centre de notifications : [contracts/notifications.md](contracts/notifications.md) |

## Règles transverses
- **Seul `web` est exposé au navigateur.** Toutes les routes `/api/*` des autres services exigent un jeton interne (`MlShared.Plug.Internal`) ; elles ne sont jamais appelées depuis le navigateur. Exception : `POST /webhooks/stripe` (billing), protégé par signature Stripe.
- Appels : `MlShared.Client.get/post/put/patch/delete(service, path, as: user_id, json: ..., params: ...)`. Le `user_id` voyage dans le jeton interne signé (`conn.assigns.user_id` côté serveur). **Un service ne fait jamais confiance à un `user_id` passé dans le corps ou l'URL pour autoriser une action « en tant que » l'utilisateur** : il utilise `conn.assigns.user_id`.
- JSON uniquement. Identifiants = UUID (chaînes). Dates = ISO 8601 UTC. Montants en centimes (`amount_cents`) + `currency`.
- Erreurs : `{"error": "<code>"}` + statut HTTP ; validation : `422 {"error":"invalid","errors":{"champ":["message"]}}`.
  Codes communs : `401 unauthorized`, `403 forbidden`, `404 not_found`, `402 premium_required`, `409 conflict`, `422 invalid`.
- Pagination : `?page=N` (1-based) → `{"entries":[...], "page":N, "total_pages":M, "total":T}` ; ou curseur pour les messages (`?before=<message_id>` → `{"entries":[...], "next_before": id|null}`).
- Événements temps réel (PubSub partagé du cluster, voir `MlShared.Events`) : voir la section de chaque service. Les services publient ; `web` s'abonne.
- Les identités de démo ont des UUID fixes (`MlShared.Demo.users/0`) : chaque service seede ses données en référençant ces UUID.
- Chaque service expose `GET /healthz` (sans jeton) → `200 {"status":"ok"}` si sa base répond.

---
## accounts (4001)
Utilisateur public (forme « user public ») : `{"id","username","display_name","bio"}`.
Utilisateur courant (« user privé ») : public + `{"email","confirmed":bool,"role":"user|moderator|admin","inserted_at"}`.

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `POST /api/users` | service | `{email,password,username,display_name?}` (password ≥ 12 car., username `^[a-z0-9_]{3,24}$`) | `201 {"user": privé}` + e-mail de confirmation envoyé (Swoosh ; en dev visible sur `http://localhost:4001/dev/mailbox`) · 422 |
| `POST /api/users/confirm` | service | `{token}` | `200 {"user": privé}` · `404 not_found` (jeton invalide/expiré, 7 jours) |
| `POST /api/users/resend-confirmation` | service | `{email}` | `204` toujours (pas d'énumération) |
| `POST /api/sessions` | service | `{email,password}` | `201 {"session_token": "...", "user": privé}` · `401 invalid_credentials` · `403 unconfirmed` (mot de passe correct mais e-mail non confirmé) · `429 locked` (5 échecs / 15 min par e-mail) |
| `GET /api/sessions/current` | service | en-tête `x-session-token` | `200 {"user": privé}` · `401` (inconnu, révoqué, expiré : 30 jours glissants) |
| `DELETE /api/sessions/current` | service | en-tête `x-session-token` | `204` (révoque) |
| `GET /api/users?ids=a,b,c` | service | ≤ 100 ids | `200 {"users":[public]}` (ids inconnus ignorés) |
| `GET /api/users/search?q=xx` | utilisateur | q ≥ 2 car. | `200 {"users":[public]}` (max 20, exclut l'appelant) |
| `GET /api/users/by-username/:username` | service | | `200 {"user": public}` · 404 |
| `PATCH /api/me` | utilisateur | `{display_name?, bio?}` | `200 {"user": privé}` · 422 |
| `PUT /api/me/password` | utilisateur | `{current_password, password}` | `204` (révoque toutes les autres sessions) · `401 invalid_credentials` · 422 |

Le jeton de session est opaque (32 octets aléatoires, Base64url), stocké **haché** (SHA-256). `web` le garde dans le cookie de session signé.

## learning (4002)
Aventure (liste) : `{"id","slug","title","summary","category":"coding|science|humanities|creative","difficulty":"beginner|intermediate|advanced","premium":bool,"duration_minutes","cover":"forest|observatory|alchemy|archive"}`.
Détail : liste + `{"description","objectives":[],"prerequisites":[],"chapters":[{"id","position","title","lessons":[{"id","position","title","kind","xp_reward","completed":bool}]}],"access":"open|premium_required|login_required","enrolled":bool,"progress":{"done","total","percent"}|null,"resume_lesson_id":id|null}`.

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `GET /api/adventures` | service (utilisateur optionnel) | `?q&category&difficulty&access=free|premium&sort=title|newest|shortest&page` | page d'aventures (6 par page) |
| `GET /api/adventures/:slug` | service (utilisateur optionnel) | | détail · 404 |
| `POST /api/adventures/:slug/enroll` | utilisateur | | `200 {"enrolled":true}` (idempotent) · `402 premium_required` |
| `GET /api/lessons/:id` | utilisateur | | `200 {"lesson":{"id","title","kind":"story|exercise|coding","body","content":{...},"xp_reward"},"adventure":{"slug","title"},"progress":{"status":"in_progress|completed","attempts","notes","draft"},"prev_id","next_id"}` · `402` · 404. Ouvrir une leçon inscrit l'utilisateur et mémorise la dernière leçon. Pour `exercise`, `content` ne contient pas la bonne réponse. |
| `POST /api/lessons/:id/submit` | utilisateur | `{"answer": string}` (+ `idempotency_key`, `revision` : rejeu hors ligne, voir [offline](contracts/offline.md)) | `200 {"correct":bool,"feedback":str,"xp":"awarded|duplicate|none","trace":[int]|null}` (+ `replayed`, `xp_reward` avec une clé) · 402 · `409 lesson_changed` · `422 idempotency_key_reused` |
| `POST /api/lessons/:id/complete` | utilisateur | (leçons `story`) (+ `idempotency_key`, `revision`) | `200 {"xp":"awarded|duplicate"}` · 422 si la leçon exige une réponse |
| `GET /api/lessons/:id/offline` | utilisateur | | `200 {"package":{…}}` : contenu public seul, `expires_at` ≤ fin de la période payée et ≤ 14 jours · `422 offline_unavailable` · `402` · `409 no_paid_period` · `503` ([offline](contracts/offline.md)) |
| `PUT /api/lessons/:id/notes` | utilisateur | `{"notes"}` (≤ 4000) | `204` |
| `PUT /api/lessons/:id/draft` | utilisateur | `{"draft"}` (≤ 2000) | `204` |
| `GET /api/me/dashboard` | utilisateur | | `200 {"level","xp","into_level","per_level","streak","week":[{"date","xp"}×7],"current":{"slug","title","percent","resume_lesson_id"}|null,"recommendations":[aventure]}` |

Droits premium : learning appelle `billing GET /api/entitlements/:user_id` (cache ETS 30 s, invalidé par l'événement `"entitlements"`). Si billing est injoignable : **refus** de l'accès premium (`503 entitlements_unavailable` sur les routes premium) : jamais d'ouverture par défaut. Contenu gratuit toujours accessible.
XP : idempotente par contrainte unique `(user_id, ref_key)` (`lesson:<id>`, `adventure:<id>` bonus 50). Leçon coding « The Looping Grove » : mini-langage borné `GroveScript` (pas d'exécution de code).

## billing (4003)
Formule : `{"key":"free|premium|vip","name","price_cents","currency":"usd","interval":"month","features":[str]}` : valeurs de démonstration configurables (0 / 1200 / 2400).
Droits : `{"user_id","plan":"free|premium|vip","status":"none|active|past_due|canceled","current_period_end":iso|null,"cancel_at_period_end":bool}`.

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `GET /api/plans` | service | | `200 {"plans":[formule],"mode":"stripe|local|disabled"}` |
| `GET /api/entitlements/:user_id` | service | | `200 droits` (free si aucun abonnement) |
| `GET /api/me/billing` | utilisateur | | `200 {"entitlements":droits,"invoices":[{"id","amount_cents","currency","status","period_start","period_end","hosted_url"|null}],"mode"}` |
| `POST /api/checkout` | utilisateur | `{"plan":"premium|vip","success_url","cancel_url"}` | `201 {"url","session_id","mode"}` · `409 already_subscribed` (même formule active) · `503 payments_disabled`. Stripe : URL Stripe Checkout (mode subscription). Local : URL `"/membership/local-checkout/<session_id>"` (page servie par web). |
| `GET /api/checkout/:session_id` | utilisateur | | `200 {"session_id","plan","status":"open|completed|expired","mode"}` (404 si la session n'appartient pas à l'utilisateur) |
| `POST /api/checkout/:session_id/simulate-payment` | utilisateur | `{"outcome":"succeeded|failed"}` | **Mode local uniquement** (sinon 404). Construit un événement de webhook signé avec le secret local et le traite par LE même pipeline que Stripe. `202 {"status":"processing"}` |
| `POST /api/me/subscription/cancel` | utilisateur | | `200 droits` (résiliation en fin de période) |
| `POST /api/me/subscription/resume` | utilisateur | | `200 droits` |
| `POST /api/portal` | utilisateur | `{"return_url"}` | `201 {"url"}` (Stripe Customer Portal) · `404` en mode local |
| `POST /webhooks/stripe` | **signature Stripe** (pas de jeton interne) | corps brut | `200` · `400 invalid_signature` |

Règles : une URL de retour de checkout n'active jamais rien ; seuls les événements de webhook signés (Stripe ou local) modifient les droits. Déduplication par `provider_event_id` unique ; événements plus anciens que le dernier appliqué ignorés ; résiliation effective en fin de période (worker Oban) ; aucune donnée de carte stockée.
Événements publiés : `"entitlements"` et `"user:<id>"` → `{:entitlements_changed, user_id, plan}`.
Centre de notifications ([contrat](contracts/notifications.md)) : chaque changement appliqué (activation,
`past_due`, résiliation programmée, `canceled`) met en file, dans la transaction du changement, une notification de la
catégorie `billing` (Oban `MlBilling.NotifyWorker`) ; un webhook rejoué n'en crée pas d'autre.
Mode : `stripe` si `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` + `STRIPE_PRICE_PREMIUM` + `STRIPE_PRICE_VIP` définis ; sinon `local` si `BILLING_LOCAL_MODE` ≠ `"false"` (défaut en dev/test) ; sinon `disabled`. En prod, le mode local est refusé.

## social (4004)
> **[contracts/social.md](contracts/social.md) fait foi** pour toutes les routes de social (formes
> complètes, groupes, pièces jointes, sourdine, réglages, routes internes, événements). Le tableau ci-dessous reste exact
> pour les routes d'origine ; les formes y sont étendues.

Membre (enrichi via accounts `GET /api/users?ids=`) : user public.
Message : `{"id","conversation_id","kind":"text|system","sender_id","body","removed","hidden","attachment","system","inserted_at"}`.
Conversation : `{"id","kind":"direct|group","name","owner_id","other":user public|null,"members":[…],"last_message":message|null,"unread":int,"muted","muted_until"}`.

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `GET /api/me/friends` | utilisateur | | `200 {"friends":[user public]}` |
| `GET /api/me/friend-requests` | utilisateur | | `200 {"incoming":[{"id","from":user}],"outgoing":[{"id","to":user}]}` |
| `POST /api/friend-requests` | utilisateur | `{"user_id"}` | `201 {"id","status":"pending"}` · `200 {"status":"accepted"}` si une demande inverse existait (acceptation mutuelle) · `409 already_friends|already_requested` · `403 blocked|friend_requests_closed` · `422 self` |
| `POST /api/friend-requests/:id/accept` | utilisateur (destinataire seulement) | | `200` · 404 |
| `POST /api/friend-requests/:id/decline` | utilisateur (destinataire ; l'émetteur peut annuler) | | `204` · 404 |
| `DELETE /api/friends/:user_id` | utilisateur | | `204` |
| `GET /api/me/blocks` · `POST /api/blocks {"user_id"}` · `DELETE /api/blocks/:user_id` | utilisateur | | bloquer supprime l'amitié et les demandes ; `204` |
| `GET /api/me/conversations` | utilisateur | | `200 {"conversations":[conversation]}` (tri par dernier message) |
| `POST /api/conversations` | utilisateur | `{"user_id"}` | `200 {"conversation":{...}}` (unique par paire, idempotent) · `403 not_friends|blocked` |
| `GET /api/conversations/:id` | utilisateur (membre) | | `200 {"conversation"}` · `404` si non membre (ne divulgue pas l'existence) |
| `GET /api/conversations/:id/messages` | utilisateur (membre) | `?before=<id>` | `200 {"entries":[message] (ordre chronologique, 30 max),"next_before":id|null}` |
| `POST /api/conversations/:id/messages` | utilisateur (membre) | `{"body"?, "attachment"?}` (texte 1–2000 car. et/ou pièce jointe) | `201 {"message"}` · `429 rate_limited` · `403 blocked|not_friends` (direct, règle réévaluée à chaque envoi) · 422 · `503 scanner_unavailable` |
| `POST /api/conversations/:id/read` | utilisateur (membre) | | `204` |
| `GET /api/me/unread` | utilisateur | | `200 {"messages":int,"friend_requests":int}` (`messages` hors conversations en sourdine) |
| `POST /api/reports` | utilisateur | `{"target_type":"user|message","target_id","reason":"harassment|spam|inappropriate|other","details"?}` | `201` (instantané du message conservé) · 422 |

Événements : chaque événement de la messagerie est livré par membre sur `"user:<id>"`, social
choisissant les destinataires au moment de l'envoi (membres actuels) : `{:new_message, message_map}`, `{:message_removed, map}`,
`{:messages_read, conversation_id, read}`, `{:conversation_changed, id}`, plus `{:unread_changed, user_id}`,
`{:friendship_changed, user_id}`, `{:social_settings_changed, user_id}`. Le topic `"conversation:<id>"` n'existe plus : `web`
ne s'abonne à aucune conversation (un membre retiré ne reçoit plus rien, même page ouverte). Détail :
[contracts/social.md](contracts/social.md).

## web (4000)
Routes navigateur : `/` (landing) · `/register` · `/login` · `/logout` (DELETE) · `/confirm/:token` · `/adventures` · `/adventures/:slug` · `/learn/:slug/:lesson_id` · `/dashboard` · `/membership` · `/membership/local-checkout/:session_id` · `/membership/success?session_id=` · `/membership/cancel` · `/friends` · `/messages` · `/messages/new` · `/messages/:id` · `/media/attachments/:id` · `/members/:username` · `/settings` · `/settings/:section` · `/notifications` · `/healthz` · `/welcome` · `/help` · `/contact` · `/legal` · `/legal/:document` (`privacy`, `terms`, `cookies`, `accessibility`) · `/admin/support` · `/admin/support/:id` · `/fonts/*` (polices auto-hébergées) · `/sw.js` · `/manifest.webmanifest` · `/icons/*` · `/offline` · `/offline/session` · `/offline/packages/:lesson_id` · `/offline/sync` (POST) · section `/settings/offline`.
Session : cookie Phoenix signé (`http_only`, `same_site: Lax`, `secure` en prod) contenant `session_token` ; chaque mount LiveView résout l'utilisateur via accounts `GET /api/sessions/current`.
Dégradation : si un service est injoignable, la page affiche un état « service temporairement indisponible » pour la zone concernée, sans planter la page ;, son bouton « Try again » (`ml:retry`, traité pour toute LiveView par `MysticWeb.Preferences`) monte de nouveau la page : toutes ses données sont vraiment redemandées.

**Pages d'accès, réseau et polices** :
- **Connexion et retour** : une page de membre ouverte sans session renvoie vers `/login?return_to=<page>` (chemin local
  vérifié par `MysticWeb.Auth.return_path/1`, jamais un autre site ni une page d'invité) ; une session refusée par
  accounts (expirée, révoquée ailleurs, mot de passe changé) ajoute `reason=expired`, expliqué sur la page de connexion.
  Après la connexion : la page demandée, sinon `/welcome` si l'accueil du compte confirmé est `pending`, sinon
  `/dashboard`. Limite : une LiveView montée par une navigation en direct (sans requête HTTP) ne connaît pas son URL, le
  retour se fait alors vers le tableau de bord.
- **États d'accès** (`MysticWeb.AccessComponents.access_state/1`, un seul composant) : liens de confirmation, de
  réinitialisation et de changement d'e-mail inutilisables, invitation expirée / révoquée / épuisée / pleine / activité
  terminée, export expiré / pas prêt / introuvable (`/settings/data?export=`), paiement expiré, déjà payé ou annulé,
  session terminée, accès Premium terminé pendant une leçon (« ended on … », d'après les droits de billing, aussi en
  direct sur `{:entitlements_changed, …}`), thème VIP en pause (tableau de bord, paramètres, annonce en direct).
- **403 / 404** : une URL inexistante ou interdite au chargement donne la page d'erreur thématique (404 / 403, avec
  des liens vers l'aide et le contact) ; la file de relecture du studio suit désormais la règle des pages du staff
  (403 pour un membre). Exceptions voulues, avec un état en ligne : une conversation, un salon ou une demande qui
  disparaît page ouverte, et les fiches du staff chargées une fois connectées parce que leur consultation est auditée
  (`/admin/members/:id`, `/admin/support/:id`).
- **Réseau** : bandeau `#connection-status` (`role="status"`, poli) piloté par `assets/js/connection.js` :
  « Reconnecting… » quand la connexion LiveView est perdue (après 1 s), « You seem to be offline » sur l'événement
  `offline`, « Retry now » qui reconnecte vraiment la socket ; tant que la connexion manque, les boutons d'envoi des
  formulaires en direct (et ceux qui poussent un événement) sont désactivés et leurs envois bloqués.
- **Polices** : auto-hébergées (`priv/static/fonts`, Fontsource 5.3.0, OFL) ; CSP `style-src 'self'`,
  `font-src 'self'` : plus aucune origine tierce.

**Leçons hors ligne (PWA)**, détail dans [contracts/offline.md](contracts/offline.md) :
- **Application installable** : `GET /manifest.webmanifest` (icônes 192, 512, maskable générées par
  `e2e/tools/make_icons.mjs`), `GET /sw.js` (service worker à la racine, `Cache-Control: no-cache`, version et précache
  des chemins digérés). Le service worker n'est enregistré que sur un appareil où un membre a rendu une leçon
  disponible hors ligne (le premier téléchargement l'installe ; « Clear offline data » et la déconnexion le retirent) ;
  il ne garde que les fichiers statiques et la page `/offline` (jamais une page du compte, une réponse d'API, `/live`
  ni un envoi).
- **Copies** : un membre Premium/VIP télécharge un récit ou un quiz premium (`GET /offline/packages/:lesson_id` →
  learning `GET /api/lessons/:id/offline`, droits revérifiés, jamais la solution) ; la copie vit dans l'IndexedDB du
  navigateur, isolée par membre, et expire (≤ 14 jours, ≤ fin de la période payée).
- **Hors ligne** : la page `/offline` (sans LiveView) liste les copies et en affiche une ; une réponse est mise en file
  « en attente de synchronisation », jamais notée sur l'appareil. **Synchronisation** (`POST /offline/sync`, CSRF) :
  chaque action est rejouée par `submit` / `complete` de learning avec sa clé d'idempotence et la révision téléchargée ;
  le vrai résultat s'affiche ; une leçon modifiée ou un accès perdu donnent un refus explicite.
- **Vie privée** : la déconnexion efface tout (page + `Clear-Site-Data: "storage"`), un autre membre sur l'appareil
  efface les données du précédent, une fin d'accès Premium (`ml:offline-purge`) supprime les copies et le dit ;
  « Clear offline data » dans `/settings/offline`.

---
## Précisions issues de l'implémentation (font foi)
**Commun** : `MlShared.Client` fusionne les en-têtes passés (`headers:`) avec le jeton interne ; GET relancés 2 fois (100 puis 200 ms). Services internes sans `force_ssl` (TLS en bordure).
**accounts** : e-mail/username normalisés (trim + minuscules, `citext`) ; `display_name` jamais nul (username par défaut) ; e-mail ≤ 160, mot de passe ≤ 72 octets ; renvoi de confirmation limité à 3/h (toujours 204) ; verrouillage par e-mail normalisé (même inexistant), 429 même avec le bon mot de passe pendant le verrouillage ; `GET /api/sessions/current` prolonge la session ; `DELETE` idempotent ; recherche = préfixe username/display_name, exclut l'appelant et les comptes non confirmés ; `?ids=` > 100 → 422.
**learning** : accès premium = `plan` ∈ {premium, vip} renvoyé par billing (formule effective, grâce d'impayé incluse) et statut ∈ {active, past_due} ; billing injoignable → détail `premium_required`, routes d'accès 503 `entitlements_unavailable`. QCM : `answer` = index 0-based (chaîne) ou texte exact du choix. Toute action sur une leçon inscrit l'utilisateur. 422 : submit sur `story`, complete sur `exercise|coding`, notes/draft trop longs (pas de troncature). GroveScript correct uniquement via `water(<variable de boucle>)`. Catalogue : page invalide → 1, au-delà → vide, `q` ≤ 100 car. Aucun événement publié.
**billing** : `success_url`/`cancel_url` obligatoires (http(s) absolues) ; le marqueur `{CHECKOUT_SESSION_ID}` est remplacé par l'UUID billing dans les deux modes. Erreurs supplémentaires : 409 `checkout_completed|checkout_expired`, 502 `provider_error`, 404 cancel/resume sans abonnement. La simulation réussie émet aussi `invoice.paid` (factures `paid|failed`) ; l'échec simulé laisse la session ouverte. Grâce `past_due` = 3 jours (`past_due_since`). Changement de formule Stripe : l'ancien abonnement est résilié avec prorata (job Oban). `PeriodEndWorker` (cron `*/15`, `Oban.Cron`) renouvelle les abonnements locaux échus non résiliés et termine ceux marqués `cancel_at_period_end`. Événement `{:entitlements_changed, ...}` à chaque modification de la ligne d'abonnement. Mode local en prod seulement avec `BILLING_LOCAL_MODE=true`. Secret local dérivé (HMAC) de `INTERNAL_SECRET` par défaut.
**social** : `GET /api/me/blocks` → `{"blocks":[user]}` ; réponses avec `id` pour accept/acceptation mutuelle/signalement ; ordre de contrôle à l'envoi : sanction (403 `restricted`) → membre (404) → débit (429 `rate_limited`, 20 / 10 s et 300 / h par membre, ETS par nœud) → blocage (403 `blocked`) → amitié (403 `not_friends`, conversations directes) → validation (422) → antivirus (422, 503) ; conversation directe conservée et lisible après blocage/retrait (envoi refusé) ; groupes de 3 à 20 membres, messages d'un membre bloqué (deux sens) masqués côté serveur pour le lecteur ; événements livrés par membre sur `"user:<id>"` (`{:new_message, map}`, `{:message_removed, map}`, `{:messages_read, id, read}`, `{:conversation_changed, id}`, `{:unread_changed, id}`, `{:friendship_changed, id}`, `{:social_settings_changed, id}`) : plus de topic `"conversation:<id>"` ni `"blocks"` ; enrichissement accounts en une requête par tranche de 100 ids, sans relance, repli `null` si accounts est indisponible ; écritures par paire sous verrou consultatif, écritures d'un groupe sous verrou de sa ligne. Réglages de confidentialité et permissions de contact détenus par social (`GET /api/internal/can-contact`, appelée par multiplayer). Contrat complet : [contracts/social.md](contracts/social.md).
