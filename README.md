# MysticLore

Plateforme d'apprentissage dans un univers d'académie fantastique : aventures interactives avec XP, badges et quêtes,
abonnements Free / Premium / VIP, amis et messagerie en temps réel, multijoueur coopératif « Le Relais des runes »,
forum, studio de création assisté par IA, centre de notifications, administration et modération, 2FA, export et
suppression des données, lecture hors ligne des leçons premium. Interface en français et en anglais.

## Architecture

Neuf applications Elixir/Phoenix dans `src/`, reliées par HTTP avec un jeton interne signé et par un PubSub partagé
en cluster Erlang. Seul `web` est exposé au navigateur ; chaque autre service a sa propre base PostgreSQL.

| Service | Port | Rôle |
|---|---|---|
| web | 4000 | interface LiveView (BFF), sans base |
| accounts | 4001 | comptes, 2FA, préférences, e-mails, sanctions, audit, données personnelles |
| learning | 4002 | aventures, leçons, XP, badges, quêtes |
| billing | 4003 | formules, checkout (Stripe test ou simulé), webhooks, crédits IA |
| social | 4004 | amis, messages, groupes, pièces jointes, blocages, signalements |
| multiplayer | 4005 | salons, parties, chat |
| community | 4006 | forum, votes, modération |
| studio | 4007 | création assistée par IA, relecture, publication |
| notifications | 4008 | centre de notifications, préférences, heures calmes |

`src/shared` contient la bibliothèque commune : jeton interne, client HTTP, événements, cluster et membres de démo.
Un service n'autorise jamais une action sur la foi d'un identifiant envoyé par le client : seul compte le `user_id`
du jeton signé. Les contrats d'API sont dans [docs/CONTRACTS.md](docs/CONTRACTS.md) et [docs/contracts/](docs/contracts/).

## Prérequis

- Elixir 1.20 et OTP 29 ;
- PostgreSQL 14 ou plus, en local ;
- Chrome et Node 20 ou plus, pour les tests de bout en bout seulement ;
- Rust et cargo, facultatifs : moteur de simulation natif (sinon learning calcule tout en Elixir).

## Commandes

```bash
bin/setup     # dépendances, bases (création, migrations, seeds), assets ; idempotent
bin/dev       # lance les 9 services en cluster (bin/dev accounts web : seulement ceux-là)
bin/stop      # arrête les services lancés par bin/dev
bin/reset     # remet les bases de dev dans l'état des seeds de démo
bin/test      # format, compilation sans avertissement et tests de tous les projets
```

- Application : http://localhost:4000
- E-mails envoyés en dev : http://localhost:4001/dev/mailbox
- Base de données : `DB_USER` (par défaut l'utilisateur système), `DB_PASSWORD` (vide par défaut), `DB_HOST` ;
  bases `ml_<service>_dev` et `ml_<service>_test`.

Sans clé Stripe, le paiement passe par un mode simulé local ; sans clé Anthropic, le studio utilise un fournisseur de
démo qui signale chaque sortie comme telle. Les variables sont décrites dans
[.env.example](.env.example).

## Comptes de démo (développement local)

Mot de passe : `mystic-demo-pass-1` (modifiable par `SEED_DEMO_PASSWORD`). Toutes ces données sont fictives.

| Nom affiché (pseudonyme) | E-mail de connexion | Rôle | Formule |
|---|---|---|---|
| Léa Moreau (`lea_moreau`) | lyra@mysticlore.test | user | Premium |
| Hugo Bernard (`hugo_bernard`) | orion@mysticlore.test | user | Free |
| Inès Petit (`ines_petit`) | mika@mysticlore.test | user | VIP |
| Sarah Lefèvre (`sarah_lefevre`) | samira@mysticlore.test | user | Free |
| Théo Garnier (`theo_garnier`) | theo@mysticlore.test | moderator | Free |
| Clara Dubois (`clara_dubois`) | aster@mysticlore.test | admin | Free |

Léa a des amis, des badges, un projet dans le studio et un groupe de discussion ; Hugo héberge un salon multijoueur
ouvert ; Théo et Clara ont accès à l'administration.

## Tests de bout en bout

Les scripts de `e2e/` pilotent le Chrome installé (playwright-core) sur la pile lancée par `bin/dev`.

```bash
cd e2e && npm install    # une fois
bin/reset && bin/dev     # données fraîches
node journeys.mjs        # puis multiplayer, community, studio, admin, formats, settings, social, notifications, pages, offline
node a11y.mjs && node keyboard.mjs && ALLOW_PENDING=1 node i18n.mjs && node responsive.mjs
```

`e2e/backend_smoke.exs` et `e2e/privacy_smoke.exs` vérifient les appels entre services ; leur en-tête donne la commande.

## Déploiement

En local avec Docker : `cp .env.example .env`, puis `docker compose up --build`.

En production, le `.env` reste sur le serveur et n'est jamais versionné. Il définit `PHX_HOST`, `WEB_URL`,
`SECRET_KEY_BASE`, `INTERNAL_SECRET`, `TOTP_ENCRYPTION_KEY`, `ERL_COOKIE`, `SEED_DEMO_PASSWORD` (secret, 16 caractères
au moins), `BILLING_LOCAL_MODE` et `SEED_DEMO=false`. Ensuite :

```bash
docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml up -d --build
```

Caddy ([deploy/Caddyfile](deploy/Caddyfile)) fournit le HTTPS, et seuls les ports 80 et 443 sont publiés.
[src/Dockerfile](src/Dockerfile) est un build multi-étapes paramétré par `SERVICE`.

Au premier démarrage, [deploy/seed-demo.sh](deploy/seed-demo.sh) crée les données de démo. Ensuite, chaque push sur
`main` dont la CI passe est déployé par [deploy.yml](.github/workflows/deploy.yml) : le serveur récupère le commit et
lance [deploy/deploy.sh](deploy/deploy.sh), qui reconstruit les images une par une, redémarre et vérifie le site. Le
serveur a 4 Go de mémoire, et deux compilations en parallèle ne tiennent pas.

## Limites connues

- Les pages juridiques sont provisoires et doivent être validées par un juriste avant une vraie mise en production.
- Stripe et Anthropic sont testés par des stubs : le vrai checkout et la vraie génération demandent vos clés.
- L'accessibilité est vérifiée par axe-core et des scripts dans Chrome, pas avec un lecteur d'écran.

Le détail est dans [docs/LIMITS.md](docs/LIMITS.md).
