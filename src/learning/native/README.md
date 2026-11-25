# Moteur de simulation natif `ml_sim` (Rust, optionnel)

Bonus du cahier des charges : une implémentation Rust des modèles `orbit` et `reaction` des leçons `simulation`
(docs/contracts/learning-formats.md). **Ce n'est pas une dépendance du cœur** : sans elle, learning calcule tout en Elixir
(`MlLearning.Sim.Orbit`, `MlLearning.Sim.Reaction`) et rend exactement les mêmes résultats.

## Construire et tester

```sh
cd src/learning/native/sim_engine
cargo test                      # 7 tests : JSON, déterminisme, bornes, valeurs de référence Elixir, réactions
cargo build --release           # → target/release/ml_sim (aucune dépendance : construit hors ligne)
mkdir -p ../../priv/native && cp target/release/ml_sim ../../priv/native/ml_sim
```

`bin/setup` le fait si `cargo` est présent (sinon : message, et repli Elixir). Équivalence avec Elixir :
`cd src/learning && mix test test/learning/sim_native_test.exs` (sautés si le binaire n'est pas construit).

## Protocole

Une exécution = une requête. `stdin` : une ligne JSON (≤ 64 Kio) ; `stdout` : le résultat JSON ; statut 0, ou 2 avec
`{"error": "…"}`. Seuls des **entiers bornés** sont acceptés (les nombres à virgule sont refusés) :

```json
{"model":"orbit","velocity":6300000,"star_mass":1000000,"planet_mass":1000,"distance":1000000,"dt":2000,"steps":1000}
{"model":"reaction","coefficients":[2,1,2],"sides":[-1,-1,1],"atoms":[[2,0],[0,2],[2,1]],"initial":[10000000,5000000,0],"yield_pct":90,"steps":6}
```

Résultat : `{"frames": [[…]] (≤ 200), "metrics": {…}}`, uniquement des entiers et des booléens (`period` peut être `null`).

## Pourquoi les résultats sont identiques

- **Virgule fixe** : learning convertit les paramètres de l'apprenant en millionièmes (entiers) après validation ; le moteur
  ne reçoit et ne rend que des entiers (arrondi `round(x × 10⁶)`, demi-valeurs loin de zéro dans les deux langages).
- **Mêmes opérations, même ordre** : l'intégrateur de Verlet n'utilise que `+ − × ÷` et `sqrt`, correctement arrondis par
  ieee 754 sur les deux plateformes, jamais de fonction transcendante (`sin`, `exp`…), ni de fma (Rust ne fusionne pas
  `a*b + c` sans `mul_add`, BEAM non plus). Le code Rust (`src/lib.rs`) suit `MlLearning.Sim.Orbit` ligne à ligne.
- `reaction` est entièrement entier (`div` tronquée, valeurs positives).
- Vérifié par `cargo test` (valeurs de référence calculées par Elixir) et par `sim_native_test.exs` : 160 entrées
  aléatoires bornées, égalité exacte des sorties.

## Intégration (`MlLearning.Sim.Native`, `MlLearning.Sim.Engine`)

- **Frontière de processus** (`Port`, `spawn_executable`), jamais de nif : un plantage du moteur ne touche pas la VM.
- **Délai** 500 ms (le processus est tué au-delà), **sortie bornée** à 256 Ko, statut 0 exigé, **sortie validée
  strictement** (clés exactes, types, nombre de trames).
- **Repli** sur Elixir, journalisé, si l'exécutable est absent, plante, dépasse le délai ou rend une sortie invalide.
- `SIM_ENGINE=auto` (défaut : natif s'il existe), `native` (absence journalisée comme une panne), `elixir` (jamais de natif).
  `SIM_ENGINE_PATH` remplace le chemin par défaut `priv/native/ml_sim`. La réponse de `POST /simulate` indique `engine`.
- Le binaire n'exécute jamais de code utilisateur et n'accède ni aux fichiers ni au réseau : il lit des nombres bornés.
