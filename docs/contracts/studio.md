# studio (4007) : contrat

Service `src/studio` (`MlStudio` / `MlStudioWeb`), base `ml_studio_*`, Oban (queues `ai`, `credits`, `publish`). Toutes les routes `/api/*` sont des routes **utilisateur** (jeton interne de `web` portant le membre) ; `GET /healthz` sans jeton.

## Accès
- Projet visible par son **propriétaire** et ses **collaborateurs** (`editor` modifie et lance l'IA, `viewer` lit). Tout autre membre (**modérateurs et admins compris**) reçoit `404 not_found` sur les routes de projet (aucun brouillon divulgué) ; un `viewer` qui modifie reçoit `403 forbidden`.
- Statut : `draft` (modifiable) → `submitted` (verrouillé, file de relecture) → `approved` (verrouillé, import learning en cours) → `published`. Modifier un projet publié le repasse en `draft` (l'aventure publiée ne change qu'à la version approuvée suivante). Modifications pendant `submitted|approved` : `409 locked`.
- Le staff (rôle `moderator|admin`, lu à chaque appel via accounts `GET /api/internal/users/:id`, accounts injoignable → `503 accounts_unavailable`) ne voit que les projets soumis/approuvés, via les routes de modération.
- Rétrogradation de formule : rien n'est retiré, tout reste modifiable à la main ; seule la génération d'image exige VIP.

## Formes
- **brief** : `{"id","owner_id","title","summary","description","objectives":[],"prerequisites":[],"audience","level":"beginner|intermediate|advanced","duration_minutes","category":"coding|science|humanities|creative","cover":"forest|observatory|alchemy|archive","status","lock_version","content_revision","review":{"decision":"approved|rejected","reason","reviewed_at"}|null,"publication":{"slug","version","published_at","message"}|null,"attestations":{"accuracy","safety","accessibility","attested_at","valid"}|null,"submitted_at","inserted_at","updated_at"}`
- **projet** : brief + `{"role":"owner|editor|viewer","modules":[module],"images":[image],"media":[média],"collaborators":[{"user_id","username","role"}]}`
- **module** : `{"id","position","title","lock_version","lessons":[leçon]}` ; **leçon** : `{"id","module_id","position","title","kind":"story|exercise|coding|video|simulation|minigame","body","xp_reward","content","lock_version","updated_at"}`
  - `story` : `content` = `{}` · `exercise` (QCM) : `{"question","choices":[…],"answer": index 0-based|null,"explanation"}` · `coding` (GroveScript) : `{"plants","starter","hints":[…]}`
  - `video` : `{"video_id": uuid|null,"captions":[{"media_id","lang","label"}],"transcript","duration_s"|null}` : `video_id` et `captions` ne sont modifiés que par les routes de médias (une autosauvegarde les ignore)
  - `simulation` : `{"model":"orbit|reaction","goal_text","steps"}` + `orbit` : `{"velocity":{"min","max","step","default"},"star_mass":{…},"distance","dt","max_eccentricity","min_revolutions"}` · `reaction` : `{"species":[{"formula","side":"reactant|product","initial"}],"max_coefficient","yield_pct","lowest_terms"}`
  - `minigame` : `{"game":"sequence|constellation","prompt","items":[…dans l'ordre attendu],"stars":[{"name","x","y"}],"path":[noms]}`
- **média** : `{"id","kind":"video|captions","content_type":"video/webm|video/mp4|text/vtt","byte_size","lang"|null,"label"|null,"inserted_at"}`
- **image** : `{"id","alt","lesson_id"|null,"content_type","byte_size","source":"upload|demo","inserted_at"}`
- **version** : `{"id","number","note","source":"manual|submission|restore","author_id","inserted_at"}` (+ `"snapshot"` en modération)
- **génération** : `{"id","project_id","lesson_id","user_id","kind":"outline|lesson_draft|feedback|image","status":"pending|running|succeeded|failed|cancelled","cost","credits":"reserved|consumed|released","provider":"demo|anthropic","model","demo":bool,"brief","result"|null,"error"|null,"retry_of","applied_at","started_at","finished_at","inserted_at"}`
- **contrôle** : `{"key":"structure|objectives|titles|quizzes|grovescript|image_alt|no_html|lengths|links|videos|simulations|minigames","ok":bool,"issues":[{"code","module","lesson","title","field","image"}]}` (positions 1-based ou `null`).

## Routes

| Méthode & chemin | Accès | Entrée | Sortie |
|---|---|---|---|
| `GET /api/projects` | membre | | `200 {"owned":[résumé],"shared":[résumé]}` résumé = `{"id","title","status","role","category","cover","level","modules_count","lessons_count","published_slug","updated_at"}` |
| `POST /api/projects` | membre | champs du brief (`title` requis) | `201 {"project"}` · 422 |
| `GET /api/projects/:id` | lecteur | | `200 {"project"}` · 404 |
| `PATCH /api/projects/:id` | éditeur | `{lock_version, …brief}` | `200 {"project": brief}` · `409 {"error":"conflict","current": brief}` · `409 locked` · 422 |
| `DELETE /api/projects/:id` | propriétaire | | `204` · `409 locked` |
| `POST /api/projects/:id/modules` | éditeur | `{title}` | `201 {"module"}` · `409 too_many_modules` (20) |
| `PATCH /api/projects/:id/modules/:module_id` | éditeur | `{lock_version, title}` | `200 {"module"}` · `409 conflict` |
| `DELETE /api/projects/:id/modules/:module_id` | éditeur | | `204` |
| `PUT /api/projects/:id/modules/order` | éditeur | `{module_ids:[tous]}` | `200 {"modules"}` · 422 |
| `POST /api/projects/:id/modules/:module_id/lessons` | éditeur | `{title, kind}` | `201 {"lesson"}` · `409 too_many_lessons` (30) |
| `PATCH /api/projects/:id/lessons/:lesson_id` | éditeur | `{lock_version, title?, body?, xp_reward?, content?}` (`content` partiel fusionné) | `200 {"lesson"}` · `409 {"error":"conflict","current": leçon}` · 422 |
| `DELETE /api/projects/:id/lessons/:lesson_id` | éditeur | | `204` |
| `PUT /api/projects/:id/modules/:module_id/lessons/order` | éditeur | `{lesson_ids:[tous]}` | `200 {"lessons"}` |
| `POST /api/projects/:id/collaborators` | propriétaire | `{username, role?: "editor"|"viewer"}` | `201 {"collaborator"}` · `404 user_not_found` · `403 blocked` (blocage social dans un sens ou l'autre) · `409 already_collaborator` · `422 self` · `503 social_unavailable` |
| `PATCH /api/projects/:id/collaborators/:user_id` | propriétaire | `{role}` | `200 {"collaborator"}` |
| `DELETE /api/projects/:id/collaborators/:user_id` | propriétaire, ou le collaborateur lui-même | | `204` |
| `GET /api/projects/:id/versions` | lecteur | | `200 {"versions"}` (plus récente d'abord) |
| `POST /api/projects/:id/versions` | éditeur | `{note?}` (≤ 200) | `201 {"version"}` |
| `POST /api/projects/:id/versions/:version_id/restore` | éditeur | | `201 {"version": nouvelle,"project"}` (restaurer = nouvelle version, l'historique est conservé) |
| `POST /api/projects/:id/images` | éditeur | `{data: base64, alt, lesson_id?}` | `201 {"image"}` · 422 (PNG/JPEG/WebP vérifiés par signature, ≤ 2 Mo, `alt` 1..300 requis) · `409 too_many_images` (30) |
| `GET /api/projects/:id/images/:image_id` | lecteur, ou staff si soumis/approuvé | | `200` octets bruts (`content-type` de l'image, `nosniff`, CSP `sandbox`, `cache-control: private`) · 404 |
| `PATCH /api/projects/:id/images/:image_id` | éditeur | `{alt, lesson_id?}` | `200 {"image"}` |
| `DELETE /api/projects/:id/images/:image_id` | éditeur | | `204` |
| `POST /api/projects/:id/lessons/:lesson_id/video` | éditeur | octets bruts (`content-type: application/octet-stream`) | `201 {"media","lesson"}` (remplace la vidéo de la leçon) · `422` (WebM (en-tête EBML + doctype `webm`) ou MP4 (boîte `ftyp`) vérifiés par signature, ≤ 50 Mo, leçon `video` exigée) · `409 too_many_media` (40) · `409 locked` · `403` (lecteur) |
| `POST /api/projects/:id/lessons/:lesson_id/captions` | éditeur | `{lang (en, pt-BR…), label (1..40), vtt}` | `201 {"media","lesson"}` (remplace la piste de même langue) · `422` (WebVTT strict : signature `WEBVTT`, 1..2000 repères horodatés valides, ≤ 256 Ko, blocs `STYLE` et balises hors WebVTT refusés) · `409 too_many_captions` (6) |
| `DELETE /api/projects/:id/lessons/:lesson_id/captions/:lang` | éditeur | | `204` · 404 |
| `GET /api/projects/:id/media/:media_id` | lecteur, ou staff si soumis/approuvé | | `200` octets (`content-type` du média, `nosniff`, CSP `sandbox`, `cache-control: private`) · 404 |
| `GET /api/media/:media_id` | **tout membre** | | `200` octets **uniquement** si le média appartient à l'instantané de la version publiée dans learning (`published_version`) · `404` sinon (brouillon, autre version, inconnu) |
| `GET /api/projects/:id/checks` | lecteur | | `200 {"checks":[contrôle],"ready":bool,"attestations"}` |
| `PUT /api/projects/:id/attestations` | propriétaire | `{accuracy, safety, accessibility}` (booléens) | `200 {"attestations"}` : déclarations de l'auteur, valides pour la `content_revision` courante seulement |
| `POST /api/projects/:id/submit` | propriétaire | | `200 {"project"}` · `422 {"error":"checks_failed","checks"}` · `422 attestations_required` · `409 not_draft` |
| `POST /api/projects/:id/withdraw` | propriétaire | | `200 {"project"}` (`submitted` → `draft`) · `409 not_submitted` |
| `GET /api/ai` | membre | | `200 {"provider":"demo|anthropic","demo","label","configured","model","external","image_generation","costs":{"outline":2,"lesson_draft":5,"feedback":2,"image":12},"share_drafts_with_ai"}` |
| `GET` / `PUT /api/me/ai-settings` | membre | `{share_drafts_with_ai: bool}` | `200 {"share_drafts_with_ai"}` (désactivé par défaut) |
| `POST /api/projects/:id/generations` | éditeur | `{kind, brief (1..2000), lesson_id? (requis pour lesson_draft/feedback ; feedback = QCM), confirm_cost}` | `202 {"generation"}` · `422` (`confirm_cost` absent…) · `409 {"error":"cost_mismatch","cost"}` · `402 {"error":"insufficient_credits","balance"}` · `402 vip_required` (image) · `422 {"error":"image_generation_unavailable","message":"image generation is not available with the configured provider"}` · `503 {"error":"ai_not_configured","message"}` · `503 credits_unavailable` · `409 too_many_generations` (5 en cours) · `409 locked` |
| `GET /api/projects/:id/generations` | lecteur | | `200 {"generations"}` (30 dernières) |
| `POST /api/generations/:id/cancel` | éditeur du projet | | `200 {"generation"}` · `409 not_cancellable` |
| `POST /api/generations/:id/retry` | éditeur | `{confirm_cost}` | `202 {"generation"}` (nouvelle génération, nouvelle réservation, `retry_of`) · `409 not_retryable` |
| `POST /api/generations/:id/apply` | éditeur | | `200 {"generation"}` (écrit le résultat dans le projet, une seule fois) · `409 already_applied|not_applicable|target_missing` |
| `GET /api/me/generations` | membre | `?page=N` | `200 {"entries":[génération + "project_title"],"page","total_pages","total"}` (historique de consommation) |
| `GET /api/moderation/queue` | staff | | `200 {"projects":[brief]}` (soumis puis approuvés, plus anciens d'abord) · `403 forbidden` |
| `GET /api/moderation/projects/:id` | staff | | `200 {"project": brief,"version": version + "snapshot","checks","attestations"}` · 404 (brouillon) |
| `POST /api/moderation/projects/:id/approve` | staff, ni propriétaire ni éditeur du projet | | `200 {"project"}` (`approved` + job d'import) · `403 own_project` · `409 not_submitted` |
| `POST /api/moderation/projects/:id/reject` | staff (idem) | `{reason}` (3..1000) | `200 {"project"}` (→ `draft`, `review.reason`) · 422 |
| `POST /api/moderation/projects/:id/retry-import` | staff | | `202 {"status":"queued"}` · `409 not_approved` |

## IA
- Fournisseur : `AI_PROVIDER=anthropic|demo` ; sinon Anthropic si `ANTHROPIC_API_KEY` est défini, sinon **DEMO** hors production (`MlStudio.AI.Deterministic` : aucune IA, sortie dérivée de l'entrée, chaque texte étiqueté « DEMO MODE : not a real AI », images SVG géométriques étiquetées DEMO). En production le défaut est Anthropic : sans clé, `503 ai_not_configured`, jamais de simulation.
- Anthropic : API Messages (`claude-fable-5-2` par défaut, `AI_MODEL`), `output_config.effort` (`AI_EFFORT`, défaut `high`), sortie JSON contrainte (`output_config.format`) puis revalidée, repli serveur en cas de refus (`fallbacks: "default"`, bêta `server-side-fallback-2026-07-01`), délais `AI_TIMEOUT_MS` (300 s). Pas d'images : `image_generation_unavailable`.
- Cycle : réservation billing `"studio:gen:<id>"` avant la mise en file → job Oban `ai` (3 tentatives, 429/5xx/529/délais réessayés) → `succeeded` ⇒ consommation, `failed`/`cancelled` ⇒ libération, exactement une fois (job `credits`, idempotent).
- **Consentement** (`share_drafts_with_ai`, par membre, désactivé par défaut) : un fournisseur externe ne reçoit que le `brief` saisi pour cette génération (et le format demandé), sauf si le demandeur ET le propriétaire du projet ont consenti : alors le contexte du projet (brief, plan, leçon visée) est ajouté. Le studio ne détient aucun message privé.

## Publication
Contrôles automatiques (`MlStudio.Publishing.Checks`, limites de l'import learning) : ≥ 1 module et ≥ 1 leçon par module (≤ 20 × 30), 1–10 objectifs ≤ 200, titres (projet 3–120, autres 1–120), QCM valide (question 1–500, 2–6 choix distincts ≤ 200, réponse parmi eux, explication 1–1000), GroveScript (`plants` 2–10, starter 1–600 octets, 1–5 indices ≤ 300), texte alternatif de chaque image, aucune balise HTML/script (transcription, objectif, consignes, éléments et étoiles compris), longueurs (résumé 1–300, description ≤ 5000, durée 5–600, texte de leçon 1–20000, XP 1–100), liens http(s) uniquement, **vidéos** (`video_file` vidéo téléversée, `video_captions` ≥ 1 piste WebVTT, `video_transcript` transcription 1–50 000, `video_duration` 1–7200 s : publication bloquée sans sous-titres ni transcription), **simulations** (`sim_model`, `sim_goal` 1–500, `sim_steps`, `sim_params` bornes dans les limites du moteur (vitesse 0–20 UA/an, masse 0,1–10 M☉, distance 0,1–10 UA, pas de temps 0,0001–0,02 an) pas divisant l'intervalle et valeur de départ sur la grille, `sim_species` 2–6 formules simples distinctes avec réactif et produit, `sim_objective`), **mini-jeux** (`game_type`, `game_prompt` 1–500, `game_items` 3–10 distincts ≤ 200, `game_stars` 3–12 noms distincts x, y 0–100, `game_path` 2–20 noms existants sans répétition immédiate).
Approbation → `MlStudio.Publishing.ImportWorker` (queue `publish`, 10 tentatives, backoff ≤ 1 h) → learning `POST /api/internal/adventures/import` (docs/contracts/learning-import.md, `premium: false`, `external_id` = projet, `version` = numéro de version soumise, `solution` = index du QCM, critère d'une simulation ; vidéo = identifiants des médias + type, jamais d'URL ; simulation `orbit` : paramètres `velocity` et `star_mass`, `fixed` = distance et pas de temps ; `reaction` : espèces `s1…sN` et un coefficient entier 1..`max_coefficient` chacune) : `200` → `published` (+ `publication.slug`) ; `404`/indisponible/5xx → reste `approved` avec `publication.message`, relancé ; `403/409/422` → définitif avec message (relance manuelle possible).
Médias : fichiers privés (`<stockage>/<projet>/<média>`), l'instantané d'une version liste les médias du projet. Un média encore utilisé par la version publiée est **conservé** quand le brouillon le remplace ou le retire (les apprenants continuent de le lire) ; les autres sont supprimés. web sert les médias publiés par `/media/studio/:media_id` (membre connecté, type déduit de la signature, fichier entier relayé : pas de requêtes partielles) et l'aperçu de l'auteur par `/studio/:id/media/:media_id`.
IA : plans et brouillons de leçon limités aux formats `story`, `exercise`, `coding` (`422 lesson_id: must be a story, quiz or coding lesson` pour un brouillon de leçon vidéo, simulation ou mini-jeu, qui exigent des médias ou un modèle).

## Événements
`"studio:project:<id>"` : `{:studio_project, project_id, %{"by","revision","status"}}` (contenu, collaborateurs ou statut modifiés) et `{:studio_generation, project_id, génération}`. `web` s'abonne seulement après un `GET /api/projects/:id` (ou l'instantané de modération) réussi.
billing publie `{:credits_changed, user_id, balance}` sur `"user:<id>"` (voir billing-credits.md).

Centre de notifications ([contrat](notifications.md)) : l'approbation et le retour en brouillon créent une
notification `review_approved` / `review_rejected` pour le propriétaire et les éditeurs (`MlStudio.NotifyWorker`, Oban,
inséré dans la transaction de la décision : durable). Seul l'identifiant du projet est transmis (ni titre de brouillon,
ni motif, ni relecteur) : web relit le titre et `review.reason` par `GET /api/projects/:id`, qui vérifie l'accès.
