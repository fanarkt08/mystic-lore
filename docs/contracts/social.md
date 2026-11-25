# social : messagerie et relations complètes (contrat)

Ce document **fait foi** pour toutes les routes de social ; il remplace et complète la section
social de [docs/CONTRACTS.md](../CONTRACTS.md). Mêmes règles transverses : jeton interne (`MlShared.Plug.Internal`),
JSON, UUID, ISO 8601 UTC, `{"error": code}`, `422 {"error":"invalid","errors":{"champ":[message]}}`. « Utilisateur » =
jeton portant un membre (`conn.assigns.user_id`, normalisé en UUID ; jamais un identifiant du corps ou de l'URL).

## Formes

- **Identité** (« user public », d'accounts) : `{"id","username","display_name","avatar"}` ; champs `null` si accounts
  ne répond pas (une requête par réponse, par tranches de 100 ids, sans relance).
- **Ami** (`GET /api/me/friends`) : identité + `"online_visible": bool` : cet ami laisse ses amis voir son statut en ligne.
- **Membre d'une conversation** : `{"user": identité, "role": "owner|member", "joined_at"}` (ordre d'ancienneté).
- **Conversation** :
  `{"id","kind":"direct|group","name":str|null,"owner_id":uuid|null,"other":identité|null,"members":[membre],
  "last_message":message|null,"unread":int,"muted":bool,"muted_until":iso|null}` : `other` pour une conversation
  directe seulement ; `name` et `owner_id` pour un groupe ; `muted_until` `null` avec `muted: true` = sourdine sans fin.
  Le détail (`GET /api/conversations/:id` et les routes qui renvoient « le groupe ») ajoute
  `"read_receipts": {"enabled": bool, "reads": [{"user_id","read_at"}]}`.
- **Message** :
  `{"id","conversation_id","kind":"text|system","sender_id":uuid|null,"body":str|null,"removed":bool,"hidden":bool,
  "attachment":pièce jointe|null,"system":{"event","actor_id","target_id","name"}|null,"inserted_at"}`
  - `removed` : retiré par la modération (ni texte ni pièce jointe) ;
  - `hidden` : dans un groupe, le lecteur et l'expéditeur ont un blocage (dans un sens ou l'autre) : ni expéditeur,
    ni texte, ni pièce jointe (web affiche « message masqué ») ;
  - `system` (texte rédigé et traduit par web) : `created` (`name`), `renamed` (`name`), `member_added`
    (`target_id`), `member_removed` (`target_id`), `member_left` (`target_id` = nouveau propriétaire ou `null`).
- **Pièce jointe** : `{"id","kind":"image|pdf","content_type","filename","byte_size","width","height","alt",
  "scan":"clean|unscanned","available":bool}` (`available: false` : fichier effacé avec le compte de l'expéditeur).
- **Réglages** : `{"show_online":bool,"read_receipts":bool,"friend_requests":"everyone|friends_of_friends|nobody",
  "group_adds":"friends|nobody","lobby_invites":"friends|nobody"}` : défauts : `true`, `true`, `everyone`, `friends`,
  `friends`.

## Routes du membre (jeton « utilisateur »)

| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `GET /api/me/friends` | | `200 {"friends":[ami]}` (tri par nom) |
| `GET /api/me/friend-requests` | | `200 {"incoming":[{"id","from"}],"outgoing":[{"id","to"}]}` |
| `POST /api/friend-requests` | `{user_id}` | `201 {"id","status":"pending"}` · `200 {"id","status":"accepted"}` (demande inverse) · `409 already_friends\|already_requested` · `403 blocked` · **`403 friend_requests_closed`** (réglage du destinataire ; une demande inverse reste acceptable) · `422 self\|invalid` |
| `POST /api/friend-requests/:id/accept` · `/decline` | | inchangé (`docs/CONTRACTS.md`) |
| `DELETE /api/friends/:user_id` · `GET /api/me/blocks` · `POST /api/blocks` · `DELETE /api/blocks/:user_id` | | inchangé |
| `GET /api/me/conversations` | | `200 {"conversations":[conversation]}` (dernier message d'abord, puis les vides) |
| `POST /api/conversations` | `{user_id}` | conversation directe, unique par paire, idempotente : `200 {"conversation"}` · `403 not_friends\|blocked` |
| `GET /api/conversations/:id` | | `200 {"conversation": détail}` · `404` (non-membre, inconnu) |
| `GET /api/conversations/:id/messages` | `?before=<id>` | `200 {"entries":[message] (30, chronologique),"next_before","users":[identité]}` : `users` : expéditeurs (non masqués) et membres cités par les messages système de la page |
| `POST /api/conversations/:id/messages` | `{body?, attachment?: {data_base64, filename?, alt?}}` | `201 {"message"}` · ordre des contrôles : `403 restricted` (sanction) → `404` → **`429 {"error":"rate_limited","retry_after":s}`** (+ en-tête `retry-after`) → `403 blocked\|not_friends` (direct) → `422` (`body`, `attachment`, `alt`) → antivirus (`422` « was rejected by the antivirus », **`503 scanner_unavailable`**) |
| `POST /api/conversations/:id/read` | | `204` (accusé publié si le lecteur et les destinataires l'autorisent) |
| `PUT /api/conversations/:id/mute` | `{duration: "1h"\|"8h"\|"24h"\|"always"}` | `200 {"conversation": détail}` · `422 {"errors":{"duration":["is invalid"]}}` · `404` |
| `DELETE /api/conversations/:id/mute` | | `200 {"conversation": détail}` |
| `GET /api/me/unread` | | `200 {"messages":int,"friend_requests":int}` : `messages` : textes des autres non lus, ni retirés ni d'un membre avec qui le lecteur a un blocage, **hors conversations en sourdine** (le `unread` de chaque conversation suit les mêmes règles mais reste compté pendant une sourdine) |
| `GET /api/attachments/:id` | | `200` octets (`content-type` du fichier, `x-content-type-options: nosniff`, `cache-control: private, no-store`) · `404` (non-membre, inconnu, message retiré, message masqué, fichier effacé) |
| `POST /api/groups` | `{name, member_ids: [uuid]}` | `201 {"conversation": détail}` · `422` (`name` : `can't be blank`, `should be at most 60 character(s)`, `must not contain control characters` ; `member_ids` : `is invalid`, `must list 2 to 19 friends`) · `403 {"error": not_friends\|blocked\|group_adds_closed, "user_id"}` (le premier membre refusé) |
| `PATCH /api/conversations/:id` | `{name}` | renommage, propriétaire : `200 {"conversation"}` · `403 not_owner` · `404` (conversation directe ou non-membre) · `422` |
| `POST /api/conversations/:id/members` | `{user_id}` | ajout, propriétaire : `200 {"conversation"}` · `403 not_owner` · `403 {"error": not_friends\|blocked\|group_adds_closed, "user_id"}` · `409 already_member\|group_full` · `422 self\|invalid` · `404` |
| `DELETE /api/conversations/:id/members/:user_id` | | retrait, propriétaire : `200 {"conversation"}` · `403 not_owner` · `422 self` (quitter : `/leave`) · `404` (pas membre) |
| `POST /api/conversations/:id/leave` | | `204` (tout membre) · `404` |
| `GET /api/me/settings` | | `200 {"settings"}` |
| `PATCH /api/me/settings` | sous-ensemble des réglages | `200 {"settings"}` · `422` par champ (aucune valeur ne devient nulle) |
| `POST /api/reports` | inchangé | un message système n'est pas signalable (`422`) ; la pièce jointe d'un message signalé est référencée |

## Routes internes (jeton de service, sans membre)

| Méthode & chemin | Sortie |
|---|---|
| `GET /api/internal/relationship?a&b` · `GET /api/internal/blocks/:user_id` | inchangées |
| `GET /api/internal/can-contact?from&to&kind=friend_request\|group_add\|lobby_invite` | `200 {"allowed":true}` · `403 {"error": blocked\|not_friends\|friend_requests_closed\|group_adds_closed\|lobby_invites_closed\|self}` · `422` (paramètres) : **appelée par multiplayer avant une invitation** |
| `GET /api/internal/users/:user_id/mutes` | `200 {"mutes":[{"conversation_id","muted_until": iso\|null}]}` (sourdines en cours ; `null` = sans fin) |
| `GET /api/internal/users/:id/export` · `DELETE /api/internal/users/:id` | appelant accounts seulement ([privacy](privacy.md)) |

## Routes du staff ([admin](admin.md))

`GET /api/moderation/reports` (+ `/:id`), `POST /api/moderation/reports/:id/resolve`, `GET /api/admin/stats` (`messages_7d` :
messages texte) inchangées. `POST /api/moderation/reports/:id/evidence` ajoute `"attachment": {"id","kind","content_type",
"filename","byte_size","available"} | null`. **Nouveau** : `POST /api/moderation/reports/:id/attachment {reason}` (≥ 10
caractères) → `200` octets de la pièce jointe du message signalé, après l'entrée d'audit
`social.report.attachment_viewed` (`metadata` : `message_id`, `attachment_id`, `kind`) · `422` (motif) · `409 no_attachment`
· `404` · `503 audit_unavailable` (rien n'est renvoyé).

## Règles (font foi)

**Conversations directes** : une par paire (`user_low` < `user_high`), ouvertes entre amis ; blocage puis amitié réévalués à
CHAQUE envoi sous verrou partagé de la paire ; restent lisibles après un blocage ou un retrait d'ami (envoi refusé), sans
filtrage des messages.

**Groupes** (`MlSocial.Groups`) : nom de 1 à 60 caractères (sans caractère de contrôle ni contrôle bidirectionnel), 3 à 20
membres créateur compris. Chaque membre ajouté (création ou ajout) doit être AMI de celui qui l'ajoute, sans blocage, et
accepter les ajouts (`group_adds: friends`) : contrôlé sous verrou partagé de chaque paire. Le propriétaire renomme, ajoute,
retire ; tout membre quitte. Le propriétaire qui part cède la propriété au membre le plus ancien (`joined_at`, puis id) ;
un groupe vide est supprimé avec ses messages et les fichiers de ses pièces jointes. Écritures sérialisées par verrou de la
ligne du groupe (`FOR UPDATE`) ; un envoi verrouille la ligne de son membre (`FOR SHARE`) : un retrait simultané attend.
Pas d'amitié exigée entre membres pour écrire dans un groupe.

**Historique d'un groupe** : il commence, pour chaque membre, à son arrivée (`joined_at`) : un membre ajouté plus tard (ou
rajouté après un départ) ne reçoit rien de ce qui a été écrit avant lui, ni dans le fil, ni comme dernier message de la
liste, ni en non-lus ; les pièces jointes d'avant répondent `404` et ces messages ne peuvent pas être signalés par lui
(`422`, comme un message inconnu). Son premier message est l'annonce de son ajout (`member_added`). Les membres déjà présents
gardent tout. Les conversations directes gardent tout leur historique.

**Blocage dans un groupe** : filtré CÔTÉ SERVEUR pour chaque lecteur : historique, dernier message de la liste, livraison
en direct (forme `hidden`), non-lus (exclus), pièces jointes (`404`), accusés de lecture (aucun entre eux).

**Accusés de lecture** : `last_read_at` du membre (posé par `POST /read`). Visibles seulement si le LECTEUR les autorise
(sinon `enabled: false`, aucun) ET pour les membres qui autorisent les leurs, sans blocage : réciprocité.

**Sourdine** : `muted_until` par membre et conversation (1 h, 8 h, 24 h, « toujours » stocké au 31/12/9999). La conversation
garde son `unread` ; elle sort de `GET /api/me/unread`. Une sourdine échue ne compte plus (pas d'événement à l'échéance :
le badge se corrige au prochain rechargement).

**Limite de débit** (`MlSocial.RateLimit`) : 20 messages par 10 s et 300 par heure et par membre (configurable :
`:message_limits`), fenêtres fixes en ETS **par nœud** ; un envoi refusé ne compte pas. `429` avant tout contrôle de
blocage, de validation ou d'antivirus.

**Pièces jointes** (`MlSocial.Attachments`) : une par message, avec ou sans texte. Type reconnu aux octets magiques
(jamais l'extension ni le type annoncé) : PNG, JPEG, WebP de 5 Mo au plus, 1 à 8192 px par côté, métadonnées retirées par
`MlShared.Image` (le même code que les avatars d'accounts) ; PDF (`%PDF-`) de 10 Mo au plus, gardé tel quel. Corps JSON
borné à 16 Mo (Base64). Texte alternatif : 300 caractères (images seulement). Nom : sans chemin ni caractère de contrôle,
100 caractères, extension réelle. Fichier écrit sous `<SOCIAL_STORAGE_DIR>/attachments/<32 hex>.<ext>` (temporaire puis
renommage) avant la transaction du message, supprimé si elle échoue. Accès vérifié à chaque téléchargement (membre
actuel ; message non retiré, non masqué ; fichier présent).

**Antivirus** (`MlSocial.Scanner`, adaptateur `MlSocial.Scanner.Clamd`, protocole INSTREAM en TCP, délai maximal
`CLAMD_TIMEOUT_MS`) : avant tout stockage. Configuré : sain → `scan: clean` ; signature trouvée → `422` ; injoignable,
trop lent ou en erreur → `503 scanner_unavailable` (refus). Non configuré : `scan: unscanned`, que l'interface affiche
(« non analysé par un antivirus ») : un fichier n'est jamais présenté comme analysé sans l'avoir été.

**Modération** : `remove_message` rend la pièce jointe inaccessible aux membres ; le fichier reste pour la preuve auditée
et les appels (`POST …/attachment`).

**Permissions de contact** (`MlSocial.Settings.can_contact/3`) : demande d'ami : `everyone`, `friends_of_friends` (au
moins un ami commun), `nobody` ; ajout en groupe et invitation de salon : `friends` (amis, sans blocage) ou `nobody`.
Refus explicites (`403` + code), sans rien révéler d'autre (ni la valeur du réglage, ni les amis communs).

**Statut en ligne** : calculé par web (`MysticWeb.Presence`, aucune donnée stockée, aucune « dernière connexion ») ; social
ne fournit que `online_visible` (réglage de l'ami). Jamais utilisé pour décider d'un accès.

## Événements : livraison par membre sur `"user:<id>"` (`MlSocial.Delivery`)

Social choisit les destinataires AU moment de la publication : les membres actuels de la conversation (un membre retiré ne
reçoit plus rien) ; il n'existe plus de topic `"conversation:<id>"`, et web ne s'abonne à aucune conversation.

| Message | Destinataires |
|---|---|
| `{:new_message, message}` | chaque membre (expéditeur compris, pour ses autres pages), forme vue par chacun (`hidden`) |
| `{:unread_changed, user_id}` | les autres membres après un message texte ; le lecteur après `read` ; le membre après une sourdine |
| `{:message_removed, message}` | chaque membre (retrait par la modération) |
| `{:messages_read, conversation_id, %{"user_id","read_at"}}` | les membres qui voient les accusés du lecteur (réciprocité, sans blocage) |
| `{:conversation_changed, conversation_id}` | membres, nom, propriétaire, sourdine (le membre) ou accusés changés ; aussi au membre qui vient de partir ou d'être retiré (sa page recharge et reçoit `404`) |
| `{:friendship_changed, user_id}` | relations (inchangé) et ami qui change `show_online` |
| `{:social_settings_changed, user_id}` | le membre (ses autres pages) |

D'autres processus abonnés à `"user:<id>"` (ex. le cache de community) ignorent ces événements.

## Notifications ([contrat du centre](notifications.md))

Social produit les catégories `messages` et `friends` du centre de notifications, AU mieux (`MlSocial.Notify`,
`MlShared.Notifications.async/1` : jamais bloquant, jamais d'échec de l'action d'origine) :

- **message texte** : une notification `message_received` pour chaque membre actuel sauf l'expéditeur (rien si la
  conversation est en sourdine pour lui (`muted_until`), rien entre membres qui ont un blocage (deux sens), rien s'il a
  déjà lu jusque-là ; clé `conversation:<id>` (agrégation), occurrence `message:<id>` ; paramètres : identifiant, sorte
  de conversation, nom du groupe) **jamais le texte** ;
- **`POST /api/conversations/:id/read`** → lecture par clé au centre (`read_at` : le moment de la lecture) ;
- **demande d'ami** reçue (`friend_request:<id>`), **acceptée** (y compris par une demande croisée) → le demandeur est
  prévenu et la notification de la demande est marquée lue ; refusée ou annulée → marquée lue ;
- **ajout à un groupe** (création, ajout) → `group_added` ; membre retiré ou parti → ses notifications du groupe lues ;
- **blocage** → `clear-between` : les notifications de la paire sont effacées, dans les deux sens.

Les événements de messagerie (`{:new_message, …}`…) et la sourdine sont inchangés ; `/settings/notifications` (web)
règle les canaux de chaque catégorie, `/settings/privacy` reste celle des permissions de contact.

## Côté web

- `/messages` (`MysticWeb.MessagesLive`, `MysticWeb.MessagesComponents`) : conversations directes et groupes (avatar,
  aperçu, non-lus, sourdine, point « en ligne » d'un ami qui l'autorise), fil en direct (`role=log`, `aria-live`), messages
  système rédigés par web, « message masqué », retrait par la modération ; panneau de détails (sourdine ; membres avec
  avatar, renommage, ajout, retrait et départ confirmés) ; envoi d'une pièce jointe avec progression et texte alternatif,
  aperçu des images (texte de repli « Image shared by … without a description »), PDF en téléchargement, mention « Not
  scanned by an antivirus » ; accusé « Seen » / « Seen by N: noms » sous mon dernier message s'il est le plus récent ;
  `429` : délai affiché, envoi suspendu le temps donné. `/messages/new` : création parmi ses amis.
- `/friends` : point « en ligne », raccourci « New group », refus de permission expliqués.
- `/settings/privacy` : statut en ligne, accusés de lecture, trois permissions ; succès annoncé (`role=status`) seulement
  après la réponse de social, erreurs à côté du champ.
- `/media/attachments/:id` (`MysticWeb.AttachmentController`) : relais pour le membre de la session (social décide) ; type
  d'après les octets, `cache-control: private, no-store`, `nosniff`, CSP `default-src 'none'; sandbox`, PDF toujours en
  `content-disposition: attachment` (le lien propose le nom), images en ligne ; `404` sinon.
- `POST /admin/reports/social/:id/attachment` (`MysticWeb.Admin.AttachmentEvidenceController`, formulaire avec motif et
  jeton CSRF) : pièce jointe d'un message signalé, toujours en téléchargement.
- `MysticWeb.Presence` : un membre est en ligne tant qu'au moins une de ses LiveViews est connectée (`MysticWeb.Auth`).

## Variables d'environnement (social)

`SOCIAL_STORAGE_DIR` (dossier privé des pièces jointes, chemin absolu ; vide ou absent : `src/social/priv/storage` en
dev ; obligatoire en production, sinon refus de démarrer : `docker-compose.yml` monte `social_data` sur `/data/social`) · `CLAMD_HOST`, `CLAMD_PORT` (3310),
`CLAMD_TIMEOUT_MS` (10000) : antivirus (sans `CLAMD_HOST` : `unscanned`). Une variable vide vaut une variable absente.
