# Dossier de conception : schémas (bloc 1 : C8, C9, C10)

Schémas du projet MysticLore, **produits à partir du code réel et des bases de développement**, pour la partie II du
mémoire (dossier de conception). Chaque schéma existe en trois fichiers de même nom :

- `.mmd` : la **source modifiable** (Mermaid 12.3.0) ;
- `.svg` : le rendu vectoriel, en **SVG pur** (aucun `foreignObject`) : il s’insère dans Word ou LibreOffice ;
- `.png` : le rendu matriciel sur fond blanc, **au moins 300 ppp** une fois la figure ajustée à une page A4 (zone
  utile 17 × 25 cm ; l’échelle va de 2 à 4 fois la taille du SVG).

Chaque rendu porte son **titre** en haut et sa **légende** en bas : notation, simplifications et sources dans le code
(`fichier:lignes`). Ces références sont **vérifiées automatiquement** : le texte cité doit figurer dans les lignes
indiquées (voir « Régénérer »).

## Liste des schémas

Format conseillé : d’après la taille du SVG. « A3 ou zoom » : figure dense, lisible en A3 paysage, ou en zoomant
dans le PDF (le PNG garde ≥ 300 ppp).

### 1. Cas d’utilisation (C10) : `01-cas-utilisation/`

Diagramme `usecase-beta` de Mermaid 12.3 : notation UML (acteurs en bonshommes, limite du système, cas en ellipses,
`«include»`, `«extend»`, généralisation à triangle creux, notes). Acteurs : Visiteur, Membre (Free, Premium, VIP),
Modérateur, Administrateur. Systèmes externes : Stripe, fournisseur d’IA (Anthropic), service d’e-mail (et l’antivirus
ClamAV, facultatif). Chaque cas renvoie à une action réelle : route du routeur web ou `handle_event` d’une LiveView.

| Fichier | Ce qu’il montre | Sources principales | Format |
|---|---|---|---|
| `uc-00-acteurs` | Acteurs, généralisations (Free / Premium / VIP, Modérateur → Membre, Administrateur → Modérateur), systèmes externes | migrations accounts et billing (`role`, `plan`), `MlLearning.Entitlements` | A4 portrait |
| `uc-01-vue-generale` | Un cas par écran du cahier des charges (12 écrans) et les acteurs concernés | `router.ex` (live_session `:public` et `:member`), `routes/*.ex` | A4 portrait |
| `uc-02-accueil-et-acces` | Écran 1 : accueil, inscription (`«include»` e-mail), connexion (`«extend»` 2FA), mot de passe oublié, aide, contact, pages juridiques, accueil guidé | `router.ex`, `routes/security.ex`, `routes/pages.ex`, `help_live.ex`, `contact_live.ex`, `welcome_live.ex` | A4 portrait |
| `uc-03-apprentissage` | Écrans 2, 3, 4, 7 : catalogue, tableau de bord, lecteur (correction serveur, XP unique), badges, premium, hors ligne | `adventure_live/*`, `learn_live.ex`, `achievements_live.ex`, `MlLearning.Entitlements` | A4 portrait |
| `uc-04-multijoueur` | Écran 5 : salons, invitations, liens, partie du Relais des runes, chat, XP de victoire | `multiplayer/*_live.ex`, `MlMultiplayer.Social`, `MlMultiplayer.Rewards` | A4 portrait |
| `uc-05-studio-credits` | Écran 6 : projet, modules, médias, collaborateurs, versions, génération IA (crédits, consentement), relecture, publication | `studio/project_live.ex`, `review_live.ex`, `MlStudio.AI` | A4 portrait |
| `uc-06-amis-messages` | Écran 8 : amis, demandes (permission de contact), messages, pièces jointes (antivirus), groupes, sourdine, signalement, notifications | `messages_live.ex`, `friends_live.ex`, `MysticWeb.Social`, `MlSocial.Settings` | A4 portrait |
| `uc-07-forum` | Écran 9 : lecture (visiteur), discussion, réponse, vote, solution, suivi, signalement, modération (audit) | `community/*_live.ex` | A4 portrait |
| `uc-08-abonnement` | Écran 10 : souscription, paiement Stripe ou simulé, webhook signé (Stripe acteur principal), résiliation, portail, administration | `membership_live.ex`, `local_checkout_live.ex`, `billing_web/router.ex` | A4 portrait |
| `uc-09-parametres` | Écran 11 : profil, préférences (thème VIP), sécurité (2FA, sessions), notifications, confidentialité, export, suppression | `settings_live.ex` | A4 portrait |
| `uc-10-administration` | Écran 12 : indicateurs, signalements (preuve sur motif), sanctions, appels, incidents, support, rôles, audit | `admin/*_live.ex`, `account/sanctions_live.ex`, `docs/admin-permissions.md` | A4 portrait |

### 2. Séquences (C10) : `02-sequences/`

Diagrammes de séquence UML. Chaque étape porte un numéro ; la légende donne, pour chaque numéro, le fichier et les
lignes d’origine. Les fragments `alt`, `opt`, `loop` et `par` reprennent les branches du code.

| Fichier | Ce qu’il montre | Format |
|---|---|---|
| `seq-a1-inscription-confirmation` | a. Inscription (bcrypt, jeton SHA-256), e-mail de confirmation (Swoosh), confirmation par `DELETE … RETURNING` (7 jours) | A4 paysage |
| `seq-a2-connexion-2fa` | a. Connexion : verrouillage compté avant bcrypt, challenge 2FA, essai réservé avant vérification, TOTP (AES-256-GCM, pas ±1, anti-rejeu), session, puis résolution à chaque page | A4 paysage |
| `seq-b-abonnement-webhook` | b. Checkout (local ou Stripe), webhook signé, pipeline unique `Webhooks.handle/3` (déduplication, verrou, `stale`, Oban dans la transaction), `{:entitlements_changed}` (learning, LiveView), page de retour en lecture seule, notification | A3 ou zoom |
| `seq-c-reponse-lecon` | c. Réponse à un quiz : droits (cache 30 s), correction serveur (`Grader`), transaction, XP unique (`ON CONFLICT`), badges, notification au mieux ; variante de rejeu hors ligne | A3 ou zoom |
| `seq-d-message-temps-reel` | d. Message : contrôles dans l’ordre du code (sanction → membre → débit → blocage → amitié → validation → antivirus), verrous, écriture, livraison par membre sur `user:‹id›`, notification | A3 ou zoom |
| `seq-e-generation-ia` | e. Génération IA : contrôles, réservation de crédits avant la transaction du studio, tâche Oban `ai`, consentement évalué dans la tâche, fournisseur Anthropic ou démo, consommation ou remboursement par `SettleWorker` | A3 ou zoom |

La séquence a est en deux parties (a1, a2) : en une seule, elle aurait compté une quarantaine d’étapes, illisibles
sur une page.

### 3. Classes (C10) : `03-classes/` (générés)

Un diagramme par service : **tous** les schémas Ecto (attributs avec leur type Ecto et leur valeur par défaut,
`«PK»`, `«FK»`, `«virtual»`, `«redact»`, `embeds_one`) et une **sélection** de modules de contexte avec leurs fonctions
clés. Une association par clé étrangère réelle, multiplicités tirées de `NOT NULL` et des index uniques, libellée par
l’association Ecto (`has_many`, `belongs_to`) ou « champ simple ». Une note rappelle qu’Elixir n’a pas de classes.

`classes-accounts` (A3 ou zoom), `classes-learning`, `classes-studio`, `classes-social`, `classes-multiplayer`,
`classes-community` (A4 paysage), `classes-billing`, `classes-notifications` (A4 portrait).

### 4. MCD (C8) : `04-mcd/`

Notation **Merise** : entité (nom, table en italique, identifiant souligné, propriétés), association en ovale (verbe,
propriétés éventuelles), cardinalités `min,max` sur les liens, `(1,1)` pour l’identification relative. Les entités
d’une **autre base** et les références **sans clé étrangère** sont en pointillés.

| Fichier | Ce qu’il montre |
|---|---|
| `mcd-00-vue-globale` | Les 8 bases regroupées par service et toutes les références d’une base à l’autre (UUID ou texte), jamais par clé étrangère |
| `mcd-accounts-1-comptes` · `mcd-accounts-2-moderation-support` | accounts en deux parties (17 tables) : comptes et sécurité ; sanctions, appels, audit, incidents, support |
| `mcd-learning` · `mcd-billing` · `mcd-social` · `mcd-multiplayer` · `mcd-community` · `mcd-studio` · `mcd-notifications` | Un MCD par domaine |

### 5. MPD (C9) : `05-mpd/` (générés)

Un MPD par base (`mpd-‹service›`), **relevé dans la base de développement réelle** (`ml_‹service›_dev`), en lecture
seule : tables, colonnes, types PostgreSQL, PK, FK (avec la règle `ON DELETE`), index et contraintes d’unicité, `NOT NULL`,
valeurs par défaut, références sans clé étrangère (`⇢`). La légende de chaque MPD liste toutes les contraintes CHECK,
les index uniques partiels et les déclencheurs. À côté :

- `05-mpd/donnees/ml_‹service›_dev.json` : le relevé brut de `pg_catalog` (colonnes, contraintes, index, déclencheurs,
  migrations appliquées) ;
- `05-mpd/ddl/ml_‹service›_dev.sql` : le schéma complet (`pg_dump --schema-only --no-owner --no-privileges`), tables
  techniques comprises.

### 6. Architecture logicielle (C10) : `06-architecture/`

| Fichier | Ce qu’il montre |
|---|---|
| `archi-01-n-tiers` | Navigateur (LiveView, service worker, IndexedDB, cookie) → web BFF → 8 services → 8 bases et fichiers privés ; PubSub du cluster, Oban, jeton HMAC, systèmes externes |
| `archi-02-dependances-services` | Composants : chaque appel HTTP signé entre services relevé dans le code (`MlShared.Client`), notifications durables ou « au mieux », export et suppression orchestrés par accounts |
| `archi-03-mode-hors-ligne` | Mode hors ligne : service worker, Cache Storage, IndexedDB, routes `/offline` de web, paquet et rejeu idempotent dans learning |

### 7. Architecture de production prévue (C10) : `07-production/`

`archi-production` : proxy inverse TLS (**prévu**), conteneurs `docker-compose.yml` et `src/Dockerfile` (**écrits,
jamais exécutés**), volumes nommés, sauvegardes (**prévu**), fournisseurs externes à configurer. Le trait plein marque
ce qui existe dans le dépôt, le pointillé orange ce qui n’existe pas encore.

### 8. Cycle de vie des données (C9) : `08-cycle-de-vie/`

`cycle-de-vie-donnees` : collecte, stockage, traitements et destinataires, durées de conservation (purges
automatiques), export, suppression à J+30 et ce qui est conservé sans donnée personnelle. Sources : `legal.ex`,
`live/legal_live.ex`, `docs/account-deletion.md`, contrats `privacy`, `notifications`, `support` et `offline`.

## Régénérer

```bash
cd e2e && npm install          # une fois : mermaid 12.3.0 (versions épinglées dans package.json et package-lock.json)
node tools/conception.mjs      # tout : mpd, classes, verifier, rendu (environ 30 s)
```

Étapes séparées :

| Commande | Effet |
|---|---|
| `node tools/conception.mjs mpd` | Relit les 8 bases `ml_‹service›_dev` **en lecture seule** (`PGOPTIONS=-c default_transaction_read_only=on`, requêtes `SELECT` sur `pg_catalog`, puis `pg_dump --schema-only`) et réécrit `05-mpd/` (`.mmd`, `donnees/`, `ddl/`). Connexion : `DB_USER`, `DB_PASSWORD`, `DB_HOST` comme `bin/setup` ; `MPD_SUFFIXE=test` pour les bases de test. |
| `node tools/conception.mjs classes` | Relit les schémas Ecto et les modules de `src/*/lib` (et les clés étrangères de `05-mpd/donnees/`) et réécrit `03-classes/*.mmd`. S’arrête si une fonction retenue n’existe plus (nom et arité) ou si un module ne nomme plus un schéma qu’il « utilise ». |
| `node tools/conception.mjs verifier` | Contrôle chaque ligne `%% @ref` de chaque `.mmd` : le fichier existe et le texte attendu figure dans les lignes citées ; sinon, il indique la ligne où le texte se trouve maintenant. À relancer après chaque modification du code. |
| `node tools/conception.mjs rendu [motif]` | Rend chaque `.mmd` (ou ceux dont le chemin contient `motif`) en `.svg` et `.png`. |

Prérequis : Node 20 ou plus, Google Chrome installé (chemin modifiable par `CHROME`), `psql` et `pg_dump` pour l’étape
`mpd` (les bases de dev doivent exister ; les services n’ont pas besoin de tourner). Les étapes `mpd` et `classes`
réécrivent leurs fichiers (en-tête « FICHIER GÉNÉRÉ ») : ne pas les modifier à la main. Les autres `.mmd` sont
écrits à la main et ne sont jamais réécrits.

**Rien n’est envoyé à l’extérieur** : la page de rendu est vide, Mermaid y est injecté depuis `e2e/node_modules`, toute
requête réseau est refusée et le script affiche le nombre de requêtes bloquées (attendu : 0). Aucun service de rendu
en ligne n’est utilisé.

### Conventions des sources `.mmd`

- `%% @titre …` : titre affiché ; `%% @legende …` : une ligne de légende (une puce si elle commence par `• `) ;
- `%% @ref ‹repère› ‹chemin depuis la racine›:‹ligne›[-‹ligne›] | ‹texte attendu›` : référence au code, vérifiée ;
- `<b>`, `<u>`, `<i>` dans un libellé : gras, souligné (identifiant Merise), italique ; le rendu les transforme en
  styles SVG (Mermaid les afficherait tels quels en SVG pur) ;
- cas d’utilisation : apostrophe typographique `’` et pas de parenthèses dans les libellés (syntaxe `usecase-beta`) ;
- classes : `%｛｝` (accolades pleine chasse) dans la source pour la valeur par défaut `%{}`, que Mermaid refuse dans un
  attribut ; le rendu affiche `%{}`.

## Outils et licences

| Outil | Version | Licence | Rôle |
|---|---|---|---|
| Mermaid (`mermaid`) | 12.3.0, épinglée | MIT | Analyse et mise en page des diagrammes, dans Chrome |
| playwright-core | 1.65.1 (déjà présent) | Apache-2.0 | Pilote le Chrome local (aucun navigateur téléchargé) |
| Google Chrome | installé sur le poste | - | Rendu SVG et capture PNG |
| PostgreSQL `psql`, `pg_dump` | 14.17 (Homebrew) | PostgreSQL | Relevé du MPD en lecture seule |

`npm install mermaid@12.3.0` ajoute 117 paquets dans `e2e/node_modules` (dépendances de Mermaid). Leurs licences,
relevées dans `package-lock.json` : MIT (67), ISC (33, dont d3), Apache-2.0 (7, dont chevrotain et playwright-core),
BSD-3-Clause (6), MPL-2.0 (axe-core, déjà présent), MPL-2.0 ou Apache-2.0 (dompurify), EPL-2.0 ou GPL-3.0 (elkjs,
moteur de mise en page optionnel de Mermaid, non utilisé ici), Unlicense (robust-predicates), MIT (khroma : licence
lue dans son fichier `license`, absente de `package-lock.json`).

**PlantUML n’est pas utilisé** : Java est absent du poste. Mermaid 12.3 contient un diagramme de cas d’utilisation
(`usecase-beta`, encore en bêta : sa syntaxe pourrait changer, d’où la version épinglée) qui produit la notation UML
attendue.

## Simplifications (toutes rappelées dans les légendes)

- **MPD** : tables techniques omises (`schema_migrations` d’Ecto, `oban_jobs` et `oban_peers` d’Oban) ainsi que les
  index non uniques ; elles figurent dans `ddl/`. Types écrits par leurs alias PostgreSQL exacts (`varchar(n)`,
  `timestamp(0)`, `time(0)`) ; contraintes CHECK écrites sans les transtypages `::text`, sans en changer le sens
  (définitions exactes dans `ddl/` et `donnees/`).
- **MCD** : dates techniques `inserted_at` / `updated_at` omises (sauf quand elles portent le sens de l’entité) ;
  références polymorphes (`target_type` + `target_id`) dessinées en une association par type de cible ; références
  par texte libre (`subject_id`, `target_id` de l’audit, `deletion_steps.service`, `ref_key` hors multijoueur) citées en
  légende sans association ; accounts découpé en deux diagrammes ; dans la vue globale, seules les entités qui portent
  une référence vers une autre base sont montrées.
- **Classes** : tous les schémas Ecto, mais seulement une sélection de modules et de fonctions publiques (« clés ») ;
  paramètres repris de la première clause (un motif de structure donne le nom de la structure, un motif de map donne
  `map`) ; les identifiants d’une autre base ne sont pas des associations.
- **Séquences** : un scénario nominal par diagramme, avec les branches d’erreur principales ; les détails de
  validation, les rendus HTML et certaines variantes (code de récupération, annulation d’une génération, échec de
  paiement simulé) sont résumés ou cités en légende.
- **Cas d’utilisation** : regroupés par écran ; les cas réservés à un rôle de contexte (hôte d’un salon, propriétaire
  d’un groupe, auteur d’une discussion) sont signalés par une note, sans acteur supplémentaire.
- **Architecture** : web n’est pas dessiné dans `archi-02` (il appelle les 8 services) ; les sujets PubSub sont listés
  dans un nœud plutôt que tracés un par un.

## Ce qui n’a pas pu être vérifié

- L’**API Stripe** et l’**API Anthropic** réelles : les séquences b et e suivent le code ; le projet ne les a testées
  que par stubs (`Req.Test`) et webhooks signés localement.
- **Docker / Compose** : jamais exécutés (pas de démon Docker) ; le schéma de production décrit les fichiers.
- Les **numéros de ligne** suivent le code actuel ; `verifier` signale tout décalage après une modification.
- Le comportement exact des bibliothèques (texte SQL généré par Ecto, verrous de PostgreSQL, Phoenix.PubSub entre
  nœuds) est décrit d’après le code qui les appelle, pas observé dans des journaux.

## Précisions du code par rapport à la documentation

Relevées en traçant les séquences ; les schémas suivent le code.

- **Messages (séquence d)** : le contrôle du blocage, comme celui de l’amitié, ne concerne que les conversations
  directes (`MlSocial.Chat.allowed/2` renvoie `:ok` pour un groupe, où un blocage masque seulement la livraison) ; une
  conversation directe est revérifiée **sous verrou**, après l’antivirus et l’écriture du fichier (`chat.ex`, `locked/3`) ;
  enfin, seul un refus 429 rend son crédit au compteur de débit : un envoi refusé plus loin (403, 404, 422, 503) reste
  compté (`rate_limit.ex`), alors que le contrat dit « un envoi refusé ne compte pas ».
- **Abonnement (séquence b)** : `POST /api/checkout/:id/simulate-payment` répond 202 `processing` après avoir traité
  les trois événements de façon synchrone ; le webhook Stripe peut aussi répondre `400 invalid_payload` (corps signé
  mais illisible), absent de `docs/CONTRACTS.md`.
