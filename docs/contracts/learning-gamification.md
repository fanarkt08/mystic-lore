# learning (4002) : gamification : badges, quêtes quotidiennes, profil public

Complète la section learning de `docs/CONTRACTS.md` (mêmes règles transverses : JSON, UUID, dates ISO 8601 UTC,
erreurs `{"error": code}`, validation `422 {"error":"invalid","errors":{…}}`).

## Formes
- **Badge public** : `{"id","slug","name","description","icon","rarity"}` (+ `"position": 1..3` dans les listes de badges équipés).
  - `icon` ∈ liste blanche heroicons (contrainte en base) : `hero-sparkles hero-sun hero-flag hero-star hero-bolt hero-academic-cap hero-trophy hero-fire hero-moon hero-users hero-book-open hero-shield-check hero-light-bulb hero-puzzle-piece hero-map hero-beaker hero-rocket-launch hero-pencil-square`.
  - `rarity` ∈ `common|uncommon|rare|epic|legendary`.
- **Succès** (badge pour l'utilisateur) : badge public + `{"criterion","earned":bool,"earned_at":iso|null,"equipped":bool,"position":1..3|null,"progress":{"current","target"}}`.
  - `criterion` ∈ `lessons_completed|lesson_completed|adventures_completed|total_xp|level|streak_days|multiplayer_wins`.
  - `progress.current` = valeur réelle du critère, bornée à `target` (égale à `target` si le badge est gagné). `lesson_completed` : 0 ou 1.
- **Quête du jour** : `{"id","slug","title","description","kind":"lessons_completed|xp_earned|note_written","target","progress","completed":bool,"xp_reward"}`.
  - `completed` ⇔ la récompense du jour est versée (alors `progress` = `target`).

## Routes
| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `GET /api/me/achievements` | utilisateur | | `200 {"badges":[succès] (ordre du catalogue),"equipped":[badge public + position] (ordre des positions),"max_equipped":3}` |
| `PUT /api/me/badges/equipped` | utilisateur | `{"badge_ids":[id…]}` : 0 à 3 identifiants distincts, dans l'ordre voulu (position 1, 2, 3) | Remplacement **atomique** (équiper, déséquiper, réordonner = envoyer la nouvelle liste ; `[]` déséquipe tout). `200` = même corps que `GET /api/me/achievements` · `422 {"error":"equip_limit_exceeded"}` (plus de 3) · `422 {"error":"badge_not_earned"}` (badge inconnu ou non gagné par l'appelant) · `422 invalid` (`errors.badge_ids`) si la liste est absente, contient un doublon ou un identifiant mal formé. Un refus ne modifie rien. |
| `GET /api/me/quests` | utilisateur | | `200 {"date":"AAAA-MM-JJ" (jour UTC),"resets_at":iso (minuit UTC suivant),"quests":[quête]}` : règle d'abord les récompenses dues (idempotent). |
| `GET /api/users/:id/profile` | service (utilisateur **optionnel** : n'importe quel membre, ou aucun) | | `200 {"user_id","level","xp","badges_earned","equipped_badges":[badge public + position],"adventures_completed"}` · `404 not_found` si `:id` n'est pas un UUID. Un UUID sans activité répond niveau 1, 0 XP (learning ne vérifie pas l'existence du compte : web n'appelle cette route qu'après accounts). |
| `GET /api/me/dashboard` | utilisateur | `?categories=` (facultatif : catégories préférées d'abord dans les recommandations, voir [accounts-profile](accounts-profile.md)) | Forme existante **inchangée** + champs additionnels `"quests":[quête]`, `"equipped_badges":[badge public + position]`, `"badges_earned":int`, `"badges_total":int`. Les quêtes sont réglées avant le calcul : `xp`, `level`, `week` incluent une récompense versée à cette lecture. |

## Règles
- **Attribution des badges** : évaluée sur les données réelles (leçons terminées, aventures terminées, événements d'XP) **après** chaque progression validée : leçon terminée (`submit` correct, `complete`), XP d'un autre service (`POST /api/internal/xp`), récompense de quête. Hors transaction : la dernière progression validée voit les contributions concurrentes. Insertion `ON CONFLICT DO NOTHING` sur l'unique `(user_id, badge_id)` : idempotente, y compris en concurrence. Aucun recalcul des badges à la lecture. Un badge gagné n'est jamais retiré.
- **Critères** : `level` = div(xp, 150) + 1 ; `streak_days` = série EN cours (jours UTC consécutifs avec de l'XP jusqu'à aujourd'hui, ou hier) au moment de l'évaluation ; `multiplayer_wins` = nombre d'événements d'XP dont `ref_key` commence par `multiplayer:` (seul le service multiplayer peut en créer, via `/api/internal/xp`) ; `lesson_completed` = la leçon de titre `param` terminée (« Sprout Tender » : `The Looping Grove`).
- **Équipement** : au plus 3, imposé côté serveur sous verrou consultatif transactionnel par utilisateur (`pg_advisory_xact_lock`), et par la base : `CHECK` (équipé ⇔ `position` ∈ 1..3, non nulle) + unique `(user_id, position)`. Seuls les badges gagnés par l'appelant (`conn.assigns.user_id`) sont acceptés.
- **Quêtes quotidiennes** (jour UTC, `ref_key` de récompense `quest:<quest_id>:<AAAA-MM-JJ>`, unique par utilisateur) :
  - `lessons_completed` : leçons dont `completed_at` est dans le jour ;
  - `xp_earned` : somme des XP du jour **hors** clés `quest:…` (une récompense de quête ne fait pas progresser cette quête) ;
  - `note_written` : leçons dont une note **non vide** a été enregistrée dans le jour (`PUT /api/lessons/:id/notes`).
  - Réglées après chaque progression (leçon, XP interne, note non vide) et à la lecture (`GET /api/me/quests`, tableau de bord). Au plus une récompense par quête et par jour, même en concurrence. Une récompense est un gain d'XP : elle compte pour l'XP totale, le niveau, la série et les badges d'XP.
- Les textes (noms, descriptions, titres) sont fournis en anglais par learning, comme les aventures.
- Centre de notifications ([contrat](notifications.md)) : chaque badge gagné crée, AU mieux, une notification
  `badge_earned` (`badge_slug`, `badge_name` ; clé `badge:<slug>` : une nouvelle tentative est sans effet).

## Seeds
10 badges (`first-spark`, `sprout-tender`, `trailblazer`, `hundred-runes`, `five-hundred-runes`, `apprentice-mage`, `archmage`, `ember-keeper`, `moonlit-week`, `duel-victor`) et 3 quêtes (`daily-lesson` 1 leçon → 15 XP, `daily-xp` 30 XP → 20 XP, `daily-note` 1 note → 10 XP), upsert par slug. Les badges des membres de démo sont attribués par l'évaluation réelle : lea_moreau en gagne 5 (Première étincelle, Main verte, Bout du chemin, Cent runes, Braise entretenue) et en équipe 3 (Main verte, Bout du chemin, Braise entretenue) seulement si elle n'en a équipé aucun. Les autres membres n'ont pas d'activité dans learning, donc aucun badge. Les quêtes du jour ne sont pas réglées par les seeds : elles le sont à la première lecture.
