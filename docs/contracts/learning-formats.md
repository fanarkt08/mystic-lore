# learning : formats vidéo, simulation et mini-jeu (contrat)

> **Implémenté** : `MlLearning.Video`, `MlLearning.Sim` (+ `Sim.Orbit`, `Sim.Reaction`, `Sim.Engine`, `Sim.Native`),
> `MlLearning.Minigame`, `MlLearningWeb.LessonController`. Testé par `test/learning/sim_test.exs`,
> `test/learning/sim_native_test.exs`, `test/learning_web/formats_api_test.exs`, `test/learning/concurrency_test.exs`,
> `test/learning_web/import_test.exs` ; côté web par `test/web_web/live/learn_formats_live_test.exs` ; en vrai par `e2e/formats.mjs`.

Trois nouveaux `kind` de leçon (contrainte `kind_valid` étendue) : `video`, `simulation`, `minigame`. Comme pour les autres
formats : `GET /api/lessons/:id` n'expose que `content` (jamais `solution`), l'accès premium est vérifié sur chaque route
(`402`), l'XP de la leçon est accordée **une seule fois** (`lesson:<id>`, contrainte unique, y compris en concurrence).

## Vidéo

`content` = `{"video": {"src", "type": "video/webm|video/mp4", "poster"|null}, "captions": [{"lang", "label", "src"}] (1–6, WebVTT),
"transcript" (1–50 000 car., obligatoire), "duration_s" (1–7200)}`. `src` / `poster` sont des **chemins servis par web**
(`/media/lessons/…` pour les médias seedés, `/media/studio/<uuid>` pour ceux du studio) : jamais d'URL externe.

| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `POST /api/lessons/:id/complete` | `{"watched_percent": 0..100}` et/ou `{"transcript_opened": true}` | `200 {"xp":"awarded|duplicate"}` · `422 {"errors":{"watched_percent":[…]}}` si `watched_percent < 80` et transcription non ouverte |
| `POST /api/lessons/:id/submit` | | `422` (`lesson: has no answer to submit`) |

**Limite assumée** : le serveur ne vérifie pas le visionnage réel. `watched_percent` est la part de la vidéo réellement lue
mesurée par le navigateur (`video.played`, hook `.VideoProgress`) ; c'est une déclaration du client. La règle évite un
« terminé » par mégarde et l'interface l'explique ; elle n'empêche pas un client modifié de déclarer 80 %.

## Simulation

`content` = `{"model": "orbit|reaction", "params": {nom: {"min","max","step","default","label","unit"}}, "goal_text", "steps"}` +
configuration du modèle. `solution` = le **critère**, jamais exposé.

- `orbit` (2 corps, Verlet « velocity » à pas fixe, UA / an / M☉, G = 4π²) : paramètres parmi `velocity` (0–20), `star_mass`
  (0,1–10), `planet_mass` (0–1), `distance` (0,1–10), `dt` (0,0001–0,02) ; les autres entrées sont dans `"fixed"` ; `steps`
  10–20 000. Arrêt si collision (< 0,01 UA) ou fuite (> 100 UA). Critère `{"max_eccentricity" (0,001–0,5), "min_revolutions" (1–10)}` :
  orbite liée, ni collision ni fuite, au moins `min_revolutions` tours, excentricité `(r_max − r_min)/(r_max + r_min)` ≤ seuil.
- `reaction` : `"species"` (2–6 : `key`, `formula` sans parenthèses, `side` `reactant|product`, `initial` 0–1000 mol, `atoms`
  déduits), un paramètre **entier** (coefficient 1–12, pas 1) par espèce, `"yield_pct"` (1–100) et `steps` = passages de la chaîne
  (1–100). À chaque passage, `ξ = min(n_i div ν_i)` sur les réactifs, `ξ·yield_pct div 100` réagit. Critère
  `{"lowest_terms": bool}` : atomes conservés pour chaque élément (et plus petits entiers si demandé).

Bornes des paramètres validées à l'import et dans les seeds : `min < max` à l'intérieur des bornes dures du modèle, `step > 0`
divisant l'intervalle (≤ 10 000 valeurs), `default` sur la grille, ≤ 6 décimales.

| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `POST /api/lessons/:id/simulate` | `{"params": {nom: nombre}}` (absents = défaut) | `200 {"model","engine":"native|elixir","columns":[{"key","label","unit"}],"frames":[[…]] (≤ 200 lignes),"plot":{"type":"path|lines",…},"metrics":{…},"description"}` · `422 {"errors":{"params.<nom>":["must be between …"|"must be … plus a multiple of …"|"must be a number"|"is not a parameter of this simulation"]}}` · `422 lesson: is not a simulation` · 402 |
| `POST /api/lessons/:id/submit` | `{"answer": "<JSON des paramètres>"}` | `200 {"correct","feedback","feedback_code","feedback_params","trace":null,"xp"}` · `422` (JSON invalide, hors bornes : **aucune tentative comptée**) |

`simulate` est un calcul pur (aucune inscription, aucune tentative). Jamais de calcul non borné : paramètres hors bornes → 422
avant tout calcul ; le moteur revérifie ses bornes dures.

Langue des textes calculés (sans rupture du contrat) : `description` et `feedback` restent les phrases anglaises de
référence. Pour les afficher dans la langue du membre, web s'appuie sur des données stables :
- la description est recomposée à partir de `metrics`, des `frames` et des valeurs envoyées ;
- les colonnes fixes (`pass`, `atoms_<élément>`, `t`, `r`) sont nommées d'après leur `key` ;
- le message de `submit` est choisi d'après `feedback_code`, avec ses `feedback_params` :
  - `reaction_balanced`, `reaction_common_factor` ;
  - `reaction_unbalanced` `{element, left, right}` ;
  - `orbit_collided`, `orbit_escaped`, `orbit_few_turns` ;
  - `orbit_elongated` `{eccentricity}` ;
  - `orbit_stable` `{eccentricity, period}`.

Pour un code inconnu, web affiche `feedback` tel quel.

### Moteurs
Valeurs en **virgule fixe** (millionièmes, entiers) avant le calcul ; le moteur ne reçoit que des entiers bornés et rend des
entiers. `orbit` n'utilise que `+ − × ÷` et `sqrt` (IEEE 754, arrondis exacts) dans un ordre fixé ; `reaction` est entièrement
entier. `SIM_ENGINE=auto` (défaut : natif s'il est construit, sinon Elixir) `|native|elixir`. Le moteur natif Rust `ml_sim`
(optionnel, `src/learning/native/README.md`) donne des résultats **identiques** (tests d'équivalence sur entrées aléatoires) ;
il est lancé par `Port` (processus séparé, délai 500 ms, sortie ≤ 256 Ko validée strictement) avec **repli** journalisé sur
Elixir en cas d'absence, de plantage, de délai dépassé ou de sortie invalide.

## Mini-jeu

- `sequence` : `content` = `{"game":"sequence","prompt","items":[{"id","label"}]}` ; `solution` = `{"order":[id]}`.
- `constellation` : `content` = `{"game":"constellation","prompt","stars":[{"id","name","x","y"}]}` (x, y 0–100, y vers le bas) ;
  `solution` = `{"path":[id]}` (une étoile peut revenir).

Identifiants opaques (8 caractères hexadécimaux du SHA-256 du libellé), liste stockée triée par identifiant. L'état initial
exposé est **mélangé de façon déterministe par (utilisateur, leçon)** et n'est jamais l'ordre attendu.

| Méthode & chemin | Entrée | Sortie |
|---|---|---|
| `POST /api/lessons/:id/submit` | `sequence` : `{"answer": "{\"moves\":[{\"id\",\"dir\":\"up|down\"}]}"}` (≤ 300, rejoués par le serveur depuis l'état initial) · `constellation` : `{"answer": "{\"moves\":[id d'étoile]}"}` (le chemin, ≤ 40) | `200 {"correct","score" (0–100, part des positions correctes),"feedback","trace":null,"xp"}` · `422` (coup impossible, id inconnu, JSON invalide : aucune tentative comptée) |

Le retour ne désigne jamais quels éléments sont bien placés (seulement combien).

## Seeds de démonstration
L'Atlas céleste : vidéo « Lire le ciel de nuit » (WebM réel de 34 s, sous-titres EN/FR, transcription), simulation `orbit`
« L'étoile errante », mini-jeu `constellation` « Tracer la Grande Ourse ». La Machine de l'alchimiste (premium) : simulation
`reaction` « Le cœur de la machine », mini-jeu `sequence` « Redémarrer la vanne ». Les Gardiens des archives : mini-jeu `sequence`
« Ordering the Sources » (sources par date).
