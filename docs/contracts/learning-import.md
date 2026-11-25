# learning : import d'une aventure publiée par le studio (contrat)

> **Implémenté** (`MlLearning.Importer`, `MlLearningWeb.ImportController`), testé par `test/learning_web/import_test.exs` : rendu jouable, solution du QCM non exposée, GroveScript corrigé avec le bon nombre de plants, idempotence, version périmée (409), conservation des identifiants et de la progression, validation (422), réservé à studio (403), formats vidéo / simulation / mini-jeu (chemins des médias construits, critère et ordre cachés, refus précis).

`POST /api/internal/adventures/import` : jeton interne de **service** (appelant `studio` uniquement, sinon 403), sans utilisateur.

Le studio publie une version **approuvée** (relue par un modérateur) d'un projet. learning crée ou met à jour l'aventure correspondante. L'opération est idempotente par `(source, external_id, version)` :
- même version importée deux fois : aucun effet, même réponse ;
- version plus ancienne que la dernière importée : `409 stale_version`.

## Corps

```json
{
  "external_id": "<uuid du projet studio>",
  "version": 3,
  "adventure": {
    "title": "Le Jardin au clair de lune",
    "summary": "≤ 300 caractères",
    "description": "≤ 5000 caractères",
    "category": "coding|science|humanities|creative",
    "difficulty": "beginner|intermediate|advanced",
    "duration_minutes": 30,
    "objectives": ["…"],
    "prerequisites": ["…"],
    "cover": "forest|observatory|alchemy|archive",
    "author_id": "<uuid accounts>",
    "chapters": [
      {
        "title": "…",
        "lessons": [
          {"title": "…", "kind": "story", "body": "…", "xp_reward": 10},
          {"title": "…", "kind": "exercise", "body": "…", "xp_reward": 20,
           "content": {"question": "…", "choices": ["…", "…"]}, "solution": 1, "explanation": "…"},
          {"title": "…", "kind": "coding", "body": "…", "xp_reward": 40,
           "content": {"plants": 4, "starter": "…", "hints": ["…"]}},
          {"title": "…", "kind": "video", "body": "…", "xp_reward": 15,
           "content": {"video": {"media_id": "<uuid média studio>", "content_type": "video/webm|video/mp4"},
                       "captions": [{"media_id": "<uuid>", "lang": "en", "label": "English"}],
                       "transcript": "…", "duration_s": 34}},
          {"title": "…", "kind": "simulation", "body": "…", "xp_reward": 30,
           "content": {"model": "orbit", "goal_text": "…", "steps": 1000,
                       "params": {"velocity": {"min": 4, "max": 9, "step": 0.1, "default": 5, "label": "Launch speed", "unit": "AU/yr"}},
                       "fixed": {"distance": 1, "dt": 0.002}},
           "solution": {"max_eccentricity": 0.03, "min_revolutions": 1}},
          {"title": "…", "kind": "minigame", "body": "…", "xp_reward": 25,
           "content": {"game": "sequence", "prompt": "…", "items": ["dans", "l'ordre", "attendu"]}},
          {"title": "…", "kind": "minigame", "body": "…",
           "content": {"game": "constellation", "prompt": "…", "stars": [{"name": "Alkaid", "x": 8, "y": 62}, …], "path": ["Alkaid", "Mizar", …]}}
        ]
      }
    ]
  }
}
```

## Règles
- **Formats acceptés** : uniquement ceux que learning sait corriger : `story`, `exercise` (QCM : `solution` = index 0-based, jamais exposé aux apprenants), `coding`, `video`, `simulation` et `minigame` (détails : [learning-formats.md](learning-formats.md)). Une leçon `coding` est un exercice GroveScript borné : « arroser les plants 0..plants-1 exactement une fois par une boucle », avec `plants` de 2 à 10.
- **Vidéo** : learning ne reprend aucune URL : il construit `"/media/studio/<media_id>"` (UUID exigés) pour la vidéo et chaque piste WebVTT. web les sert par un proxy authentifié ; le studio ne délivre que les médias de la version **publiée** (docs/contracts/studio.md). Sous-titres (1–6, langues distinctes) et transcription (1–50 000) obligatoires, durée 1–7200 s.
- **Simulation** : `content` et `solution` (le critère) validés par `MlLearning.Sim.validate/2` : modèle autorisé (`orbit`, `reaction`), bornes à l'intérieur des limites du moteur, grille ≤ 10 000 valeurs, défaut sur la grille, critère dans ses bornes ; libellés et unités par défaut du modèle s'ils manquent.
- **Mini-jeu** : la liste fournie est l'ordre attendu (`items`, ou `path` de noms d'étoiles) ; learning la convertit en identifiants opaques + `solution` et la présente mélangée à chaque apprenant. `sequence` 3–10 libellés distincts ≤ 200 ; `constellation` 3–12 étoiles (noms distincts ≤ 60, x, y entiers 0–100), chemin de 2–20 noms sans répétition immédiate.
- **XP par défaut** : story 10, exercise 20, coding 40, video 15, simulation 30, minigame 25 (1–100 si fourni).
- **Erreurs** : le message d'une leçon refusée précise la cause (`chapter 1, lesson 2: invalid "simulation" lesson (params.velocity: …)`).
- **Contenu gratuit uniquement** : le studio publie avec `premium: false`.
- **Slug** : dérivé du titre à la première importation, puis stable.
- **Stabilité de la progression** : chapitres et leçons sont rapprochés par leur position, ce qui conserve leurs identifiants et donc la progression des apprenants. Les éléments en trop sont supprimés seulement s'ils n'ont aucune progression ; sinon ils sont conservés et ajoutés en fin de liste.
- **Réponse** : `200 {"adventure_id", "slug", "version"}`. Erreurs : `422 {"error":"invalid","errors":{…}}`, `409 stale_version`, `403 forbidden` si l'appelant n'est pas studio.
