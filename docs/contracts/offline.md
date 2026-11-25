# Leçons hors ligne (PWA) : contrat

> **Implémenté** :
> - learning : `MlLearning.Offline`, `MlLearning.Offline.Action`, `MlLearning.Entitlements.fresh/1`, migration
>   `20261124140000_add_offline_lessons` (révision des leçons tenue par un déclencheur, table `idempotent_actions`) ;
> - web : `MysticWeb.Offline`, `MysticWeb.OfflineController`, `MysticWeb.OfflineHTML` (page `/offline`),
>   `MysticWeb.OfflineComponents`, `MysticWeb.LessonContent` (rendu commun à la leçon et au paquet),
>   `assets/js/service_worker.js`, `assets/js/offline.js`, `assets/js/offline_store.js`, `assets/js/connection.js` ;
>   icônes générées par `e2e/tools/make_icons.mjs`.
>
> **Testé par** : learning `test/learning_web/offline_api_test.exs` (15 tests) et `test/learning/concurrency_test.exs`
> (même clé en parallèle, hors bac à sable) ; web `test/web_web/offline/offline_test.exs` (29 tests) ; en vrai par
> `e2e/offline.mjs` (Chrome, `context.setOffline`).

## Périmètre

- Seules les leçons **`story`** (récit) et **`exercise`** (quiz) d'une aventure **premium** sont proposées hors ligne,
  à un membre dont la formule ouvre les aventures premium (formule effective `premium` ou `vip`, statut `active` ou
  `past_due`, d'après billing). Les leçons gratuites et les autres formats (`coding`, `video`, `simulation`,
  `minigame`) ne le sont pas.
- Le paquet ne contient jamais la solution, l'explication ni l'indice d'un quiz : seulement ce que la page de la leçon
  affiche avant toute réponse.
- Hors ligne, rien n'est corrigé sur l'appareil : une réponse (ou un récit terminé) est **mise en file** et affichée
  « en attente de synchronisation ». Le serveur la corrige à la synchronisation, par les routes habituelles.

## learning (4002)

### Révision d'une leçon

`lessons.revision` (entier ≥ 1) et `lessons.revised_at` sont tenus par le déclencheur PostgreSQL
`lessons_track_revision`, quel que soit le chemin d'écriture (seeds, import du studio, SQL manuel) :

- à l'insertion : `revision = 1`, `revised_at = now()` ;
- à la modification : `revision + 1` et `revised_at = now()` si le titre, la sorte, le texte (`body`), le contenu
  public (`content`) ou la solution changent ; sinon inchangées (un upsert identique des seeds ne les touche pas ; la
  position ou l'XP seules non plus). Aucune valeur envoyée par l'application n'est prise.

### `GET /api/lessons/:id` (inchangé, un champ en plus)

`"offline": {"available": bool, "revision": int, "max_days": 14}` : `available` : la leçon peut être téléchargée
(premium, `story` ou `exercise`) ; l'accès lui-même reste celui de la route (402 sinon).

### `GET /api/lessons/:id/offline` : paquet hors ligne

Jeton **utilisateur**. Sans effet de bord : ni inscription, ni « dernière leçon ». Droits relus chez billing sans le
cache de 30 s (`GET /api/entitlements/:user_id`, cache rafraîchi au passage).

| Résultat | Corps |
|---|---|
| `200` | `{"package": {"lesson": {"id","title","kind","body","content","xp_reward","revision","revised_at"}, "adventure": {"slug","title"}, "member_id", "downloaded_at", "expires_at", "expires_by": "max_days|period_end", "max_days": 14}}` |
| `404 not_found` | leçon inconnue |
| `422 offline_unavailable` | leçon gratuite, ou sorte autre que `story` / `exercise` |
| `402 premium_required` | la formule n'ouvre pas les aventures premium |
| `409 no_paid_period` | formule premium, mais pas de période payée en cours : fin inconnue, ou déjà passée (grâce d'un impayé) |
| `503 entitlements_unavailable` | billing injoignable (jamais d'ouverture par défaut) |

**Expiration** : `expires_at = min(maintenant + 14 jours, current_period_end)` (`expires_by` dit laquelle s'applique).

### `POST /api/lessons/:id/submit` et `POST /api/lessons/:id/complete` : rejeu idempotent

Mêmes routes, mêmes contrôles et même correction qu'en ligne (`Grader`, `Progress`), avec deux champs facultatifs :

| Champ | Valeur | Erreur |
|---|---|---|
| `idempotency_key` | UUID choisi par le navigateur, un par action mise en file | `422 invalid` `{"errors":{"idempotency_key":["must be a UUID"]}}` |
| `revision` | révision de la leçon téléchargée (entier ≥ 1) ; exige une clé | `422 invalid` (`revision` : `must be a positive integer` ; `idempotency_key` : `is required with a revision`) |

Ordre des contrôles : leçon et accès (`404`, `402`, `503`) → sorte (`422`) → réponse (`422`, pour `submit`) →
paramètres de rejeu (`422`) → puis, dans une transaction :

1. la clé est réservée (unique par `(user_id, key)`, `INSERT … ON CONFLICT DO NOTHING`) ; une requête concurrente de
   même clé attend la fin de la première puis lit son reçu ;
2. **déjà vue** : même action, même leçon, même réponse → le reçu est rendu tel quel avec `"replayed": true`, rien
   n'est recompté (ni tentative, ni XP, ni quête) ; autre demande → `422 {"error":"idempotency_key_reused"}` ;
3. **nouvelle** : la leçon est relue et verrouillée (`FOR SHARE`) ; si `revision` diffère →
   `409 {"error":"lesson_changed","revision":<actuelle>}` (jamais corrigée contre un autre énoncé) ; sinon correction,
   progression et XP (unique par leçon, comme en ligne), puis le reçu garde la réponse.

Un refus annule tout (rien n'est compté ni gardé : la même clé pourra être renvoyée). Réponse `200` : la réponse
habituelle + `"replayed": bool` et `"xp_reward"` (XP de la leçon). Badges et quêtes sont réévalués après validation,
seulement pour une XP réellement accordée par cette requête.

**Date de la série** : learning ne lit aucune date du navigateur. Une action synchronisée compte le **jour (UTC) de
sa synchronisation** pour l'XP du jour, la série, la semaine, les quêtes et l'objectif quotidien.

### Données personnelles

Table `idempotent_actions` (`user_id`, `key`, `lesson_id`, `action`, `request_hash` = SHA-256 de l'action, de la
leçon et de la réponse (jamais la réponse elle-même), `response` = le résultat rendu, `inserted_at`) : exportée
(`offline_actions` : clé, leçon, action, résultat, date de synchronisation) et supprimée avec le compte. Conservée
jusqu'à la suppression du compte (un reçu effacé laisserait une action rejouée compter une seconde tentative).

## web (4000)

| Méthode & chemin | Accès | Sortie |
|---|---|---|
| `GET /sw.js` | public | le service worker : `text/javascript`, `Cache-Control: no-cache`, CSP `default-src 'self'`. Précédé de `VERSION` (empreinte du script et de la liste), `SHELL = "/offline"` et `PRECACHE` (chemins de `Endpoint.static_path/1` : digérés en production par `mix phx.digest`) |
| `GET /manifest.webmanifest` | public | `application/manifest+json` : nom, `display: standalone`, `start_url: /dashboard`, couleurs `#090E20`, icônes 192, 512 et `maskable` 512 (`/icons/*`), langue du visiteur (`ml_locale` ou `Accept-Language`) |
| `GET /offline` | public | la page hors ligne : document complet sans LiveView, sans jeton CSRF ni donnée du membre (seulement sa langue et ses préférences d'affichage), `Cache-Control: no-cache` ; textes traduits dans `data-texts` |
| `GET /offline/session` | membre (cookie) | `{"member_id","csrf_token","premium": bool|null,"message": str|null}` : `premium` d'après billing (`null` s'il ne répond pas : rien n'est supprimé sur une supposition) ; `message` : « Your Premium access ended on … » · `401` sans session |
| `GET /offline/packages/:lesson_id` | membre | `{"package": {format, member_id, lesson_id, kind, title, xp_reward, revision, revised_at, adventure, html, downloaded_at, expires_at, expires_by, max_days}}`, `Cache-Control: no-store` ; `html` = texte et question rendus par `MysticWeb.LessonContent` (le chemin de la page de la leçon, tout échappé) · erreurs de learning reprises avec `{"error","message"}` traduit (`402`, `409`, `422`, `404`, `503`) · `401` · `429` |
| `POST /offline/sync` | membre + `x-csrf-token` | corps JSON ≤ 128 Ko `{"actions":[{"key","lesson_id","kind":"submit|complete","answer"?,"revision"}]}` (50 au plus, dans l'ordre) → `{"results":[…],"purge": null|{"message"}}` · `400` corps invalide · `401` · `403` CSRF · `429` |

Résultat d'une action : `done` (`correct`, `xp`, `replayed`, `title`, `message` = retour du serveur, `xp_text`),
`refused` (`reason` : `lesson_changed`, `access_ended`, `not_found`, `invalid` ; jamais compté) ou `retry`
(`reason: unavailable` : learning ne répond pas, l'action reste en file). Après un `402`, les actions suivantes sont
refusées sans être envoyées et `purge` porte le message daté de la fin d'accès. Limite de débit : 120 requêtes par
minute et par IP (`MysticWeb.RateLimit`, `:offline`).

Événements LiveView → navigateur : `ml:offline-purge` `{message}` : poussé par `MysticWeb.Auth` sur
`{:entitlements_changed, _, plan}` sans formule payante, et par `LearnLive` quand une leçon premium répond `402` avec
un accès terminé. Déconnexion (`DELETE /logout`) : en-tête `Clear-Site-Data: "storage"`.

## Navigateur

- **Service worker** (`scope: "/"`, `updateViaCache: "none"`) : enregistré seulement sur un appareil où un membre a
  rendu une leçon disponible hors ligne : le premier « Make available offline » l'installe, puis les pages du membre
  le tiennent à jour tant que la base existe ; un membre qui ne télécharge rien n'a ni worker, ni cache, ni base. Il
  met en cache `mysticlore-static-<VERSION>` = les fichiers statiques (`/assets/`, `/fonts/`, `/icons/`, `/images/`,
  `/favicon.ico`) et la page `/offline`, rien d'autre. Il n'intercepte que des GET du même site, jamais `/live`.
  Navigation d'une page (document, pas un cadre) : réseau seulement, jamais mise en cache ; hors ligne → la page
  `/offline`, qui nomme la page demandée. Fichiers digérés (`?vsn=d`) : cache d'abord ; autres : réseau d'abord (copie
  rafraîchie, seulement si le cache existe encore : un cache supprimé n'est jamais recréé par une page restée
  ouverte). Installation : précache ; activation : suppression de tous les autres caches `mysticlore-*`. Message
  `ml:precache` (avec un `MessagePort`) : remplit le cache et répond `{ok}` : un téléchargement n'est annoncé
  « disponible hors ligne » qu'une fois le cache rempli.
- **IndexedDB** `mysticlore-offline` (créée seulement au premier téléchargement) : `meta` (membre de l'appareil),
  `packages` (copies), `queue` (actions en attente : `key` UUID, `member_id`, `lesson_id`, `kind`, `answer`, `revision`,
  `queued_at`), `reports` (20 derniers résultats). Une copie expirée n'est jamais affichée : elle est supprimée.
- **Isolation** : à chaque page de membre (et à la synchronisation), si l'appareil appartient à un autre membre, tout
  est effacé avant usage. **Déconnexion** : la page efface la base, les caches et le service worker avant d'envoyer la
  déconnexion (3 s au plus), puis le serveur demande `Clear-Site-Data: "storage"` (efficace même sans le script).
  **Fin d'accès** (`ml:offline-purge`, ou `premium: false` constaté à la connexion suivante) : copies supprimées et
  avis poli « Your Premium access ended on … » ; les réponses en attente restent et seront refusées explicitement à la
  synchronisation si l'accès est toujours terminé. **« Clear offline data »** (paramètres) : base, caches ET service worker
  supprimés, comme à la déconnexion ; rien n'est recréé avant le prochain téléchargement.
- **File** : une action en attente au plus par leçon (le formulaire est désactivé tant qu'elle attend, avec la
  raison) ; synchronisation automatique au chargement d'une page en ligne et à l'événement `online`, et par
  « Synchronize now » ; une seule à la fois (Web Locks).
- `connection.js` : les vues `[data-offline-ok]` ne sont jamais bloquées ; hors ligne, quand l'appareil garde des
  leçons ou des réponses, le bandeau dit qu'elles fonctionnent toujours, compte les actions « en attente » et mène à
  `/offline`.

## Choix et justifications

- **N = 14 jours** (constante du contrat, `MlLearning.Offline.max_days/0` et `MysticWeb.Offline.max_days/0`, à changer
  ensemble) : couvre deux semaines sans connexion (voyage, vacances) tout en bornant la durée pendant laquelle une copie
  survit à une fin d'accès sur un appareil qui ne se reconnecte pas ; c'est environ la moitié d'une période mensuelle,
  donc un membre qui se connecte au moins toutes les deux semaines peut toujours retélécharger ; et une leçon modifiée
  ne reste périmée sur un appareil que 14 jours au plus. La fin de la période payée raccourcit toujours ce délai.
- **Série** : une action hors ligne compte le jour de sa synchronisation (aucune date du client n'est crue : ni
  triche par l'horloge de l'appareil, ni série rétroactive).
- **Pas de signature du paquet** : rien n'empêche de copier ou de modifier une copie sur l'appareil (documenté) ; la
  sécurité tient au serveur : accès, révision et correction sont revérifiés à la synchronisation.
