# accounts : profil enrichi et préférences (complément de la section accounts de `docs/CONTRACTS.md`)

Paramètres complets et profil enrichi. Mêmes règles transverses que `docs/CONTRACTS.md`
(JSON, UUID, dates ISO 8601 UTC, `{"error": code}`, `422 {"error":"invalid","errors":{…}}`). Toutes les routes exigent
le jeton interne (`MlShared.Plug.Internal`) ; « utilisateur » = jeton portant un membre existant et actif.

## Formes
- **Identité** (« user public », **modifié**) : `{"id","username","display_name","avatar"}`. Toujours visible, elle
  accompagne chaque contribution (forum, messages, amis, salons). Renvoyée par `GET /api/users?ids=`,
  `GET /api/users/search`, `GET /api/users/by-username/:username` et `GET /api/internal/users/:id`.
  **La bio n'y figure plus** : elle relève du reste du profil, filtré par sa visibilité (ci-dessous). social, community et
  multiplayer transmettent désormais `avatar` au lieu de `bio`.
- **Avatar** : `null` (initiales affichées par web) · `{"kind":"crest","key":"moon|star|flame|leaf|key|book"}` (blason
  préréglé, `priv/static/images/crests/<key>.svg` de web) · `{"kind":"image","key":"<32 hex>.png|jpg|webp"}` (image
  téléversée ; la clé change à chaque téléversement).
- **User privé** (le membre lui-même : `GET /api/me`, `GET /api/sessions/current`, `PATCH /api/me`…) : identité +
  `bio`, `pronouns` (≤ 40 car.), `interests` (≤ 6 clés), `cover` (`forest|observatory|alchemy|archive|null`),
  `profile_visibility` (`public|members|friends|private`) et `preferences` :

  | Clé | Valeurs | Défaut |
  |---|---|---|
  | `language` | `auto` (navigateur) · `en` · `fr` | `auto` |
  | `time_zone` | `auto` (fuseau du navigateur) · nom IANA connu de la base `tz` | `auto` |
  | `theme` | `system` · `light` · `dark` · VIP : `grove` · `ember` · `parchment` | `system` |
  | `reduce_motion`, `high_contrast`, `underline_links` | booléens | `false` |
  | `text_size` | `100` · `112` · `125` · `150` (%) | `100` |
  | `captions` | booléen : sous-titres actifs par défaut dans les leçons vidéo | `true` |
  | `daily_xp_goal` | `10` · `20` · `50` · `100` | `20` |
- **Centres d'intérêt** (liste fixe) : `astronomy alchemy botany mathematics coding logic history languages mythology
  writing art music`.
- **Profil vu par un lecteur** : `{"id","username","display_name","avatar","cover","visibility",
  "details": {"bio","pronouns","interests"} | null, "academy_record": bool}`. `details` est `null` et
  `academy_record` faux quand la visibilité ne s'étend pas à ce lecteur.

## Routes

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `GET /api/me` | utilisateur | | `200 {"user": privé}` |
| `PATCH /api/me` (**étendu**) | utilisateur | `{display_name?, bio?, pronouns?, interests?, cover?, profile_visibility?}` | `200 {"user": privé}` · `422` (`pronouns` : longueur, `must not contain control characters` ; `interests` : `has an invalid entry`, `should have at most 6 item(s)`, `is invalid` ; `cover`, `profile_visibility` : `is invalid`, `can't be blank`) |
| `PATCH /api/me/preferences` | utilisateur | sous-ensemble des préférences | `200 {"user": privé}` · `422` (par champ ; `time_zone` : `is not a known time zone` ; aucune ne peut devenir nulle) · `403 vip_required` · `503 entitlements_unavailable` |
| `PUT /api/me/avatar` | utilisateur | corps brut de l'image (`content-type: application/octet-stream`), 2 Mo au plus | `200 {"user": privé}` · `422 {"errors":{"avatar":[…]}}` : `must be a PNG, JPEG or WebP image`, `must be at most 2 MB`, `must be between 64 and 2048 pixels wide and high`, `is not a valid image file` |
| `PUT /api/me/avatar/crest` | utilisateur | `{crest}` | `200 {"user": privé}` (l'image téléversée éventuelle est supprimée) · `422 {"errors":{"crest":["is invalid"]}}` |
| `DELETE /api/me/avatar` | utilisateur | | `200 {"user": privé}` (initiales) |
| `GET /api/avatars/:name` | service | | `200` octets de l'image actuelle d'un compte actif, `content-type` d'après le format, `x-content-type-options: nosniff` · `404 not_found` (nom invalide, ancien, compte supprimé) |
| `GET /api/users/by-username/:username/profile` | service ; le `sub` du jeton est le lecteur (absent = visiteur) | | `200 {"profile": profil vu par ce lecteur}` · `404` (inconnu, compte supprimé) |
| `GET /api/me/profile-preview?as=visitor\|member\|friend` | utilisateur | | `200 {"profile": …}` : même fonction de filtrage que la route précédente · `422 {"errors":{"as":["is invalid"]}}` |
| `POST /api/admin/users/:id/avatar/reset` | staff (moderator, admin) | `{reason}` (5 à 500 car.) | `200 {"user": membre vu du staff}` (sans avatar : rien n'est fait ni audité) · `403` · `404` · `422` |
| `PUT /api/me/onboarding` | utilisateur | `{status}` : `completed` \| `skipped` \| `pending` | `200 {"user": privé}` (`onboarding.at` posé pour `completed`/`skipped`, effacé pour `pending`) · `422 {"errors":{"status":["is invalid"]}}` |

`AdminJSON.member` (routes du staff) gagne `avatar`.

Événement : `"user:<id>"` → `{:profile_changed, user_id}` après chaque modification du profil, des préférences ou de
l'avatar (réinitialisation par le staff comprise). web recharge alors le membre (`GET /api/me`) dans ses pages ouvertes.

### learning (ajout)
`GET /api/me/dashboard?categories=science,creative` : les aventures non commencées des catégories données passent d'abord
(dans l'ordre donné), puis gratuites avant premium, puis par titre ; catégories inconnues ignorées ; sans paramètre,
ordre inchangé.

## Règles (font foi)
**Validation** : tout côté serveur, sur `conn.assigns.user_id` uniquement. Pronoms : texte libre facultatif (vide →
`null`), espaces de bord retirés, 40 caractères au plus, sans caractère de contrôle (catégorie Unicode Cc) ni contrôle
bidirectionnel (U+202A–U+202E, U+2066–U+2069). Centres d'intérêt : doublons retirés (ordre conservé), liste fixe, 6 au
plus. Préférences : changements partiels sur la valeur enregistrée ; fuseau vérifié dans la base IANA embarquée (`tz`,
aucun accès réseau).

**Thème VIP** : passer à `grove`, `ember` ou `parchment` exige la formule VIP effective : accounts appelle billing
`GET /api/entitlements/:user_id` (jeton de service ; `plan` = `vip` et statut `active|past_due`). Autre formule →
`403 vip_required` ; billing injoignable ou réponse inattendue → `503 entitlements_unavailable` (refus, jamais
d'ouverture par défaut). Un thème VIP déjà enregistré ne bloque pas les autres réglages : seul un changement de thème
vers un thème VIP est vérifié. L'application côté web est revérifiée à chaque page (voir « Côté web »).

**Avatar** (`MlAccounts.Avatars`, `MlShared.Image` (code partagé avec les pièces jointes de social), Elixir pur, sans bibliothèque d'images) :
- type reconnu aux octets magiques uniquement (PNG, JPEG, WebP ; jamais l'extension ni le type annoncé) ; 2 Mo au plus
  (lecture du corps bornée) ; dimensions lues dans les en-têtes (IHDR, SOFn, VP8/VP8L/VP8X), de 64 à 2048 px par côté ;
- métadonnées retirées en recopiant la structure : PNG → seuls IHDR, PLTE, IDAT, IEND, tRNS, gAMA, cHRM, sRGB, iCCP,
  sBIT, bKGD, pHYs sont gardés (plus de tEXt/zTXt/iTXt, eXIf, tIME ni de chunk privé) ; JPEG → APPn retirés sauf APP0
  « JFIF » et APP14 « Adobe » (donc EXIF/GPS, XMP, ICC), COM retirés, y compris entre les balayages d'une image
  progressive ; WebP → chunks EXIF et XMP retirés, drapeaux VP8X et taille RIFF recalculés ;
- stockage sous `ACCOUNTS_STORAGE_DIR/avatars/<32 hex aléatoires>.<ext>` (fichier temporaire puis renommage) ; chaque
  changement verrouille la ligne du membre (`FOR UPDATE`) et l'ancien fichier n'est supprimé qu'après l'écriture en
  base ; contrainte : jamais blason ET image ;
- seule l'image actuelle d'un compte actif est servie ; la réinitialisation par le staff est auditée
  (`accounts.avatar.reset`, motif, `metadata.kind` = `image|crest`).

**Visibilité** (`MlAccounts.Profiles`, filtrage dans accounts, une seule fonction `view/2` pour la page et l'aperçu) :

| Lecteur → / visibilité ↓ | visiteur | membre | ami | bloqué (dans un sens ou l'autre) | soi-même |
|---|---|---|---|---|---|
| `public` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `members` (défaut) | - | ✓ | ✓ | ✓ | ✓ |
| `friends` | - | - | ✓ | - | ✓ |
| `private` | - | - | - | - | ✓ |

Identité, couverture et réglage de visibilité restent toujours visibles ; « ✓ » ouvre `bio`, `pronouns`, `interests` et
la fiche de l'académie. Lecteur sans membre dans le jeton, inconnu ou en suppression → visiteur. social
(`GET /api/internal/relationship`) n'est interrogé que pour un profil `friends` : ami = `friends: true` et
`blocked: false` ; social injoignable → pas ami (refus par prudence). L'aperçu (`as=visitor|member|friend`) applique
`view/2` à la catégorie demandée : il est égal à ce que reçoit un vrai lecteur de cette catégorie (vérifié par test).

**Fiche de l'académie** : learning `GET /api/users/:id/profile` reste lisible par tout appelant interne ; c'est web qui ne
l'appelle que si accounts a répondu `academy_record: true` (la décision reste dans accounts, learning n'a pas à
connaître les amitiés ni la visibilité ; le navigateur n'atteint jamais learning).

**Données personnelles** : l'export (`accounts.profile`) ajoute `pronouns`, `interests`, `cover`,
`profile_visibility`, `avatar` (`{"kind":"crest","key"}` ou `{"kind":"image","content_type","data_base64"}`) et
`preferences`. L'anonymisation efface ces champs (préférences par défaut) puis supprime le fichier de l'avatar.

## Côté web
- **Application à chaque page** (`MysticWeb.Preferences`, après `MysticWeb.Auth` dans les deux `live_session`) :
  - langue : `en`/`fr` du membre, sinon (auto, visiteur) cookie `ml_locale` puis `Accept-Language` ;
  - fuseau de `MysticWeb.Format` : celui du membre, sinon celui du navigateur transmis par les paramètres de connexion du
    LiveSocket (`Intl…timeZone`, validé, jamais enregistré), sinon UTC ;
  - attributs de `<html>` : `lang`, `data-theme`, `data-motion="reduce"`, `data-contrast="more"`,
    `data-text-size="112|125|150"`, `data-links="underline"` + `<meta name="color-scheme">`, rendus par le gabarit racine
    et poussés (`ml:prefs`) quand ils changent pendant que la page est ouverte. CSS : `assets/css/features/preferences.css`
    (aucun style ni script en ligne).
- **Thème VIP** : appliqué seulement si billing (`GET /api/entitlements/:id`, à chaque montage, uniquement pour un thème
  VIP) répond `vip` ; sinon `system` et mention « VIP theme paused » dans les paramètres. `{:entitlements_changed, id,
  plan}` met en pause ou rétablit le thème des pages ouvertes.
- **Dates et heures** : un seul utilitaire, `MysticWeb.Format` (`date/1`, `datetime/1`, `time/2`, `message_time/1`,
  `from_local_input/1`), qui convertit dans le fuseau de la page et ajoute l'abréviation (`14:05 CET`). Les jours de
  l'académie (quêtes, série, graphique des 7 jours, objectif du jour) restent des jours UTC de learning ; leur renouvellement
  est affiché à l'heure locale.
- **Visiteur** : sélecteur de langue du pied de page → `POST /locale` (formulaire protégé par CSRF) : cookie `ml_locale`
  (1 an, `SameSite=Lax`, `HttpOnly`, `Secure` en production), retour vers `return_to` ou, à défaut, le `Referer` du même
  hôte, seulement s'il s'agit d'un chemin local (`/…`, ni `//`, ni schéma, ni `\`, ni caractère de contrôle), sinon `/`.
- **Paramètres** : `/settings` (= profil) et `/settings/:section` (`profile`, `account`, `security`, `preferences`,
  `accessibility`, `learning`, `privacy` (« Privacy », réglages détenus par social : statut en ligne, accusés de lecture,
  permissions de contact) voir [social](social.md)), `data` (« Privacy & data » : visibilité + aperçu, export,
  suppression), et `notifications` (après `learning` : canaux par catégorie et heures calmes,
  détenus par le centre de notifications : voir [notifications](notifications.md)). Succès annoncé (`role=status`)
  seulement après la réponse du service ; erreurs à côté du champ.
- **Profil** `/members/:username` : ouvert aux visiteurs (aucune action de membre pour eux).
- **Avatars** : `<.avatar>` (image, blason ou initiales) et `<.identity>` (avatar, nom affiché, `@pseudonyme`) sur le forum,
  les messages, les amis et les salons. `/media/avatars/:key` relaie l'image d'accounts : type d'après les octets,
  `nosniff`, `cache-control: public, max-age=86400, immutable` (la clé versionne), CSP `sandbox`, 2 Mo au plus.
- **Tableau de bord** : objectif quotidien (XP du jour de learning) ; centres d'intérêt → catégories (`astronomy alchemy
  botany mathematics` → science, `coding logic` → coding, `history languages mythology` → humanities, `writing art music` →
  creative), la plus représentée d'abord, envoyées à learning (`?categories=`).

## Accueil guidé
- **User privé** (**modifié**) : + `"onboarding": {"status": "pending"|"completed"|"skipped", "at": iso|null}`. Un compte
  créé par l'inscription commence `pending` ; les comptes qui existaient avant la migration et les membres de démo des
  seeds sont `completed` (les parcours existants ne passent pas par l'accueil). L'export (`accounts.onboarding`)
  contient l'état ; `{:profile_changed, id}` est publié à chaque changement.
- **web** : après la connexion (mot de passe, ou second facteur), un compte **confirmé** dont l'accueil est `pending`
  va sur `/welcome` (`MysticWeb.Auth.after_login_path/2`) : sauf si une page à retrouver (`return_to`) existe, qui
  passe d'abord. Cinq étapes, chacune enregistrée par les routes existantes avec leur validation : langue et fuseau
  (`PATCH /api/me/preferences`), centres d'intérêt (`PATCH /api/me`), objectif quotidien et accessibilité
  (`PATCH /api/me/preferences`), puis les recommandations réelles de learning (`GET /api/me/dashboard?categories=`).
  « Back », « Skip this step » (rien n'est enregistré) ; la fin ou le choix d'une aventure enregistre `completed`,
  « Skip the welcome tour » enregistre `skipped` : l'accueil n'est plus proposé. `/settings/preferences` → « Restart
  the welcome tour » (`pending`, puis `/welcome`).

## Variables d'environnement
`ACCOUNTS_STORAGE_DIR` (accounts) : dossier privé des avatars, chemin absolu (vide ou absent : `src/accounts/priv/storage`
en dev ; obligatoire en production, sinon le service refuse de démarrer : `docker-compose.yml` monte `accounts_data` sur
`/data/accounts`).
