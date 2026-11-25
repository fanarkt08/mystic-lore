# multiplayer (4005) : activités, salons et « Le Relais des runes »

Service `src/multiplayer` (`MlMultiplayer` / `MlMultiplayerWeb`), base `ml_multiplayer_*`. Toutes les routes `/api/*`
exigent le jeton interne (`MlShared.Plug.Internal`) **portant un utilisateur** (UUID, sinon `401 unauthorized`) ;
chaque action est autorisée sur `conn.assigns.user_id` uniquement (jamais sur un identifiant du corps ou de l'URL).
`GET /healthz` (sans jeton) → `200 {"status":"ok"}`.

## Rôles et visibilité
Rôle de l'appelant, recalculé à chaque requête : `host` · `player` (membres actifs) · `pending` (demande en attente) ·
`invited` (invitation en attente) · `spectator` (salon ouvert, non membre).
- Salon **privé** (ou fermé, ou id inconnu/mal formé) : `404 not_found` pour qui n'y a aucun rôle, quelle que soit l'action (IDOR).
- Membre **exclu** par l'hôte : `403 banned` (bannissement du salon : ni vue, ni retour, ni invitation, ni lien).
- Salon visible mais action non permise au rôle : `403 forbidden` (ex. action d'hôte par un joueur, chat par un spectateur).

## Formes
- Membre : user public d'accounts `{"id","username","display_name","bio"}` (champs `null` si accounts est indisponible).
- Salon (résumé) : `{"id","title","visibility":"open|private","requires_approval":bool,"max_players":2..4,"member_count","status":"waiting|playing|closed","starts_at":iso|null,"host":membre,"inserted_at"}` (+ `"role"` dans `/api/me/lobbies`).
- Vue d'un salon (`GET /api/lobbies/:id`, propre à l'appelant) :
  `{"lobby":résumé,"role","members":[{"user":membre,"host":bool,"ready":bool,"connection":"online|disconnected|absent","joined_at"}],"requests":[{"user","requested_at"}],"invites":[{"id","invitee":membre,"inserted_at"}],"links":[lien],"my_invite_id":id|null,"match":partie|null}`
  : `requests`, `invites`, `links` ne sont remplis que pour l'hôte.
- Lien : `{"id","state":"active|expired|revoked|exhausted","max_uses","uses","expires_at","revoked_at","inserted_at"}` (+ `"token"` à la création seulement).
- Partie (dernière partie du salon) : `{"id","status":"active|won|lost|aborted","reason":null|"not_enough_players"|"abandoned","players":[membre] (ordre de jeu),"current_player":id|null,"attempts":[{"n","user_id","sequence":[5 runes],"marks":["hit|present|miss"×5],"hits","present"}],"max_attempts":6,"attempts_left","absent":[id],"my_hints":[indice],"secret":[5 runes]|null,"started_at","finished_at","xp_reward":50,"my_reward":{"amount","status":"pending|awarded|failed"}|null}`
  : `my_hints` = indices de l'appelant seulement (`[]` pour un spectateur) ; `secret` = `null` tant que la partie est en cours.
- Rune : entier 0..7 (noms côté interface : Ember, Storm, Mist, Stone, Sun, Moon, Star, Eye).
- Indice : `{"kind":"at","pos":0..4,"rune"}` · `{"kind":"not_at","pos","rune"}` · `{"kind":"present","rune"}` · `{"kind":"absent","rune"}` · `{"kind":"before","a","b"}` (`a` quelque part avant `b`).
- Message : `{"id","lobby_id","user_id","user":membre,"body","inserted_at"}`.

## Routes
| Méthode & chemin | Rôle requis | Entrée | Sortie |
|---|---|---|---|
| `GET /api/lobbies` | utilisateur | `?page=N` | page `{"entries":[résumé],"page","total_pages","total"}` (20/page, plus récents d'abord) : salons ouverts non fermés, hors ceux dont l'appelant est membre/demandeur/exclu et hors hôte bloqué (deux sens) · `503 social_unavailable` |
| `POST /api/lobbies` | utilisateur | `{title (3–60), max_players (2–4), visibility, requires_approval?, starts_at? (ISO UTC, futur, < 30 j)}` | `201 vue` (l'appelant est hôte et premier membre) · `422 invalid` · `409 too_many_lobbies` (3 salons non fermés par hôte, tenu en concurrence) |
| `GET /api/me/lobbies` | utilisateur | | `200 {"lobbies":[résumé + role]}` (membre ou demandeur, salons non fermés) |
| `GET /api/lobbies/:id` | tout rôle | | `200 vue` · 404 · `403 banned` |
| `POST /api/lobbies/:id/join` | spectateur, invité | | `200 {"status":"joined|pending"}` (`pending` si approbation requise ; une invitation en attente en dispense ; idempotent) · `409 full` · `403 blocked` (blocage avec un membre, deux sens) · `403 banned` · `503 social_unavailable` |
| `POST /api/lobbies/:id/leave` | hôte, joueur, demandeur | | `204` ; l'hôte qui part est remplacé par le plus ancien membre ; le dernier départ ferme le salon (`closed`) · `403 forbidden` |
| `POST /api/lobbies/:id/ready` | hôte, joueur | `{ready: bool}` | `204` · `409 in_progress` · `422 invalid` |
| `POST /api/lobbies/:id/start` | hôte | | `201 {"match_id"}` (joueurs = membres prêts et non absents) · `409 not_enough_ready` (< 2) · `409 not_yet` (avant `starts_at`) · `409 in_progress` |
| `POST /api/lobbies/:id/transfer` | hôte | `{user_id}` (membre actif) | `204` · `404` · `422` (soi-même) |
| `POST /api/lobbies/:id/kick` | hôte | `{user_id}` (membre ou demandeur) | `204` (exclusion = bannissement ; invitations révoquées) · `404` · `422` (soi-même) |
| `POST /api/lobbies/:id/requests/:user_id/approve` | hôte | | `204` (capacité et blocages revérifiés) · `404` (pas de demande) · `409 full` · `403 blocked` |
| `POST /api/lobbies/:id/requests/:user_id/decline` | hôte | | `204` · `404` |
| `POST /api/lobbies/:id/heartbeat` | hôte, joueur | | `204` (battement ~10 s, voir Connexion) |
| `POST /api/lobbies/:id/attempts` | hôte, joueur | `{sequence: [5 runes distinctes]}` (intention seulement) | `200 {"match": partie}` · `409 not_your_turn\|finished\|no_match\|conflict` · `403 not_participant` · `422 invalid` (`errors.sequence`) |
| `POST /api/lobbies/:id/reports` | hôte, joueur | `{user_id, reason: harassment\|spam\|inappropriate\|other, details?}` (cible : membre, actuel ou passé, de ce salon) | `201 {"id"}` : transmis à social `POST /api/reports` **au nom de l'appelant** (`target_type: "user"`, `details` préfixé de « Multiplayer lobby <id> ») · `404` · `422` (validation social) · `503 social_unavailable` |
| `GET /api/lobbies/:id/messages` | hôte, joueur | `?before=<message_id>` | `200 {"entries":[message] (chronologique, 50 max),"next_before":id\|null}` : messages des membres ayant un blocage avec le lecteur (deux sens) exclus côté serveur · `503 social_unavailable` · `422` (curseur) |
| `POST /api/lobbies/:id/messages` | hôte, joueur | `{body}` (1–500 car. après trim) | `201 {"message"}` · `429 rate_limited` (5 messages / 10 s par membre et par salon, compté en base sous verrou) · `422` |
| `POST /api/lobbies/:id/invites` | hôte | `{user_id}` | `201 {"invite":{"id","lobby_id","invitee":membre,"status":"pending"}}` : décidé par social (`GET /api/internal/can-contact?kind=lobby_invite` : amis seulement, sans blocage, et réglage « qui peut m'inviter dans un salon » de l'invité, [social](social.md)) · `403 not_friends\|blocked\|lobby_invites_closed` (refus de social ; `blocked` aussi pour un blocage avec un membre du salon) · `403 banned` · `409 already_member` · `503 social_unavailable` |
| `GET /api/me/invites` | utilisateur | | `200 {"invites":[{"id","inviter":membre,"lobby":résumé,"inserted_at"}]}` (en attente ; salons non fermés ; hors invitant bloqué ; hors salon dont il est membre ou exclu) · `503` |
| `POST /api/invites/:id/accept` | invité (destinataire) | | `200 {"lobby_id"}` (sans approbation ; capacité, blocages, exclusion revérifiés) · `404` (pas son invitation) · `409 full` · `403 blocked\|banned` · `410 closed` |
| `POST /api/invites/:id/decline` | invité | | `204` · `404` |
| `POST /api/lobbies/:id/links` | hôte | `{max_uses? (1–20, déf. 5), expires_in_minutes? (5–10080, déf. 60)}` | `201 {"link": lien + "token"}` : jeton 32 octets aléatoires (Base64url), stocké haché (SHA-256), rendu une seule fois · `409 too_many_links` (5 actifs) · `422` |
| `DELETE /api/lobbies/:id/links/:link_id` | hôte | | `204` (idempotent) · `404` |
| `POST /api/links/preview` | utilisateur | `{token}` (corps, jamais l'URL) | `200 {"lobby": résumé}` · `404 not_found` (inconnu) · `410 expired\|revoked\|exhausted\|closed` : aucune donnée du salon dans ces erreurs |
| `POST /api/links/join` | utilisateur | `{token}` | `200 {"lobby_id"}` (consomme un usage sous verrou du lien : `max_uses` tenu en concurrence ; un membre déjà présent n'en consomme pas ; sans approbation) · `404` · `410 …` · `409 full` · `403 blocked\|banned` |

Codes : `401 unauthorized` · `403 forbidden|banned|blocked|not_friends|not_participant` · `404 not_found` ·
`409 full|too_many_lobbies|too_many_links|in_progress|not_yet|not_enough_ready|already_member|not_your_turn|finished|no_match|conflict` ·
`410 expired|revoked|exhausted|closed` · `422 invalid` · `429 rate_limited` · `503 social_unavailable` (social injoignable : l'action est refusée, jamais ouverte par défaut).

## Le Relais des runes (« The Rune Relay » en anglais ; coopératif, 2–4 joueurs)
- Moteur pur et déterministe `MlMultiplayer.RuneRelay` : la graine (aléatoire forte au démarrage) et les joueurs déterminent l'ordre de jeu, la séquence secrète (5 runes distinctes parmi 8) et les indices (faits vrais) répartis entre joueurs : chacun en a au moins un, et leur réunion n'admet qu'une séquence parmi les 6 720 possibles.
- Tour par tour (absents sautés), 6 tentatives ; chaque tentative est notée par position (`hit` bonne place · `present` mauvaise place · `miss` absente). Victoire = séquence exacte ; défaite = tentatives épuisées ; `aborted` si moins de 2 joueurs restent membres (`not_enough_players`) ou si tous sont absents depuis 10 min (`abandoned`).
- Un `MatchServer` (GenServer, Registry + DynamicSupervisor) par partie, seul écrivain : il valide l'intention, écrit les événements dans `match_events` (séquence `(match_id, seq)` unique, contrôlée sous verrou de la partie) puis publie. Il est reconstruit par rejeu du journal après arrêt/crash/redémarrage.

## Connexion (sans Presence comme source de vérité)
La page envoie `POST /api/lobbies/:id/heartbeat` toutes les ~10 s (`last_seen_at` en base). Sans battement depuis **30 s** → `disconnected` ;
60 s de grâce plus tard (**90 s**) → `absent` : sauté dans les tours. Au battement suivant → `online`, réintégré ; la page relit l'état exact.
Balayage toutes les 5 s (`MlMultiplayer.Sweeper`) ; seuils dans `config :multiplayer, :rules`.

## Récompense
Victoire → 50 XP via learning `POST /api/internal/xp` (`ref_key` `"multiplayer:match:<match_id>"`) pour chaque participant présent à la fin
(ni absent, ni parti). Lignes `match_rewards` créées dans la transaction qui écrit la victoire (unique `(match_id, user_id)`), livrées
aussitôt puis relancées tant que learning échoue (5 s, 10 s, 20 s… plafonné à 10 min, y compris après redémarrage) ; un refus 422 →
`failed` (journalisé). Visible par chacun dans `match.my_reward`.

## Événements (PubSub du cluster)
- `"lobby:<id>"` → `{:lobby_changed, lobby_id}` (membres, prêts, hôte, partie, connexion, récompense) · `{:chat_posted, lobby_id}`.
  Aucun indice, secret ni contenu : `web` relit sa vue (`GET /api/lobbies/:id`, `GET …/messages`) et ne s'abonne qu'après un GET réussi.
- `"user:<invité>"` → `{:lobby_invite, %{"id","lobby_id","lobby_title","inviter_id"}}` (web recharge la liste des invitations).
- Centre de notifications ([contrat](notifications.md)) : chaque invitation crée, AU mieux, une notification
  `lobby_invite` (`invite_id`, `lobby_id`, `lobby_title` ; clé `lobby_invite:<id>`), annoncée par le toast de web ;
  accepter ou refuser l'invitation la marque lue.

## Données de démo (seeds, UUID de `MlShared.Demo`)
« Relais du soir » : salon ouvert hébergé par hugo_bernard (id `…b001`). « Relais entre amies » : salon privé de lea_moreau et ines_petit
(`…b002`) avec une partie gagnée (`…c001`) et son journal (4 événements) ; leurs 50 XP sont créées en attente et livrées par le service dès qu'il tourne.
