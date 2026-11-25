# MlCommunity : forum communautaire de MysticLore (port 4006)

Catégories, discussions et réponses (texte brut, un niveau), édition par l'auteur pendant 30 minutes, suppression
logique, solution, suivi avec notification temps réel, votes « utile » (unicité en base), recherche et filtres,
signalements avec instantané, modération par le staff (rôle lu chez accounts) avec journal, filtrage des blocages
(social) dans les requêtes et limite de 10 publications / 10 minutes. API JSON interne (jeton `MlShared.Plug.Internal`,
jamais appelée par le navigateur) : voir `docs/contracts/community.md`. Base `ml_community_dev` / `ml_community_test`.

    mix setup          # dépendances, base, migrations (catégories comprises), seeds de démo (idempotents)
    mix phx.server     # http://localhost:4006/healthz
    mix test

Variables : `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `PORT` (4006), `ACCOUNTS_URL`, `SOCIAL_URL`, `NOTIFICATIONS_URL`, `CLUSTER_NODES`
(PubSub partagé avec `web` et social : notifications et invalidation du cache des blocages) ; en prod `INTERNAL_SECRET`,
`DATABASE_URL`, `SECRET_KEY_BASE`.

Option prudente : si social est injoignable, toute requête d'un membre répond `503 blocks_unavailable` (les visiteurs
lisent toujours) ; si accounts est injoignable, personne n'a les droits du staff (modération `503 roles_unavailable`).
