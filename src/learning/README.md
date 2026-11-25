# learning : MysticLore (port 4002)

Service interne (jamais appelé par le navigateur) : catalogue, leçons, inscriptions, progression, XP,
tableau de bord, badges et quêtes quotidiennes. Contrats : `docs/CONTRACTS.md` (section learning),
`docs/contracts/learning-gamification.md` (badges, équipement ≤ 3, quêtes, profil public, champs ajoutés au tableau de bord),
`docs/contracts/learning-import.md` (import du studio), `docs/contracts/learning-formats.md` (vidéo, simulation, mini-jeu)
et `docs/contracts/offline.md` (révision des leçons tenue par un déclencheur, paquet hors ligne
`GET /api/lessons/:id/offline`, rejeu idempotent de `submit` / `complete` par `idempotency_key` et `revision`).

Moteur de simulation natif optionnel (Rust, processus séparé, repli Elixir) : [native/README.md](native/README.md).

```sh
mix setup            # deps, base ml_learning_dev, migrations, seeds (idempotents)
mix phx.server       # http://localhost:4002/healthz
mix test             # base ml_learning_test
```

Variables : `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `PORT` (4002), `BILLING_URL` (défaut http://localhost:4003), `NOTIFICATIONS_URL` (défaut http://localhost:4008),
`SIM_ENGINE` (`auto` par défaut, `native`, `elixir`), `SIM_ENGINE_PATH` (défaut `priv/native/ml_sim`),
`INTERNAL_SECRET` (obligatoire en prod), en prod aussi `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_SERVER=true`.
