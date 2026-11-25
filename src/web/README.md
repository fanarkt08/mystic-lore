# web : interface navigateur MysticLore (port 4000)

Seul service exposé au navigateur (Phoenix LiveView, aucune base). Il appelle accounts, learning, billing et
social via `MlShared.Client` (jeton interne signé) et s'abonne au PubSub du cluster (`MlShared.Events`) pour le
temps réel (messages, non-lus, amitiés, droits, notifications : cloche, toast, `/notifications`,
`/settings/notifications` : `MysticWeb.Notifications` rédige les textes et calcule les liens).

Pages juridiques provisoires (`/legal…`, `MysticWeb.Legal`), aide (`/help`, recherche côté serveur),
contact (`/contact`) et file du staff (`/admin/support`), accueil guidé (`/welcome`), états d'accès partagés
(`MysticWeb.AccessComponents`), bandeau de connexion (`assets/js/connection.js`), polices auto-hébergées
(`priv/static/fonts`, `assets/css/fonts.css` : Fontsource 5.3.0, licences OFL à côté des fichiers).

Leçons hors ligne (PWA, `docs/contracts/offline.md`) : service worker `/sw.js`
(`assets/js/service_worker.js`, lu à la compilation par `MysticWeb.OfflineController`, précache des chemins de
`Endpoint.static_path/1`), manifeste `/manifest.webmanifest` et icônes `priv/static/icons` (générées par
`e2e/tools/make_icons.mjs`), page `/offline` (`MysticWeb.OfflineHTML`, sans LiveView), routes JSON `/offline/session`,
`/offline/packages/:id`, `/offline/sync` (`MysticWeb.Offline`), copies et file dans IndexedDB (`assets/js/offline.js`,
`assets/js/offline_store.js`), section `/settings/offline`. Le texte et le quiz d'une leçon sont rendus par
`MysticWeb.LessonContent`, pour la page et pour la copie hors ligne.

## Lancer

    mix setup        # dépendances + binaires tailwind/esbuild + assets
    mix phx.server   # http://localhost:4000 : ou `bin/dev` à la racine pour les 9 services

## Variables d'environnement

| Variable | Rôle |
|---|---|
| `PORT` | port HTTP (défaut 4000) |
| `WEB_URL` | URL publique de web, utilisée pour les URL de retour du paiement (défaut `http://localhost:4000`, obligatoire en prod) |
| `ACCOUNTS_URL`, `LEARNING_URL`, `BILLING_URL`, `SOCIAL_URL`, `MULTIPLAYER_URL`, `COMMUNITY_URL`, `STUDIO_URL`, `NOTIFICATIONS_URL` | URL des services (défauts `http://localhost:4001` … `4008`) |
| `INTERNAL_SECRET` | secret des jetons internes (valeur de dev fournie ; obligatoire en prod) |
| `CLUSTER_NODES` | nœuds Erlang reliés (temps réel inter-services, cf. `bin/dev`) |
| `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER` | production |

## Traductions

Textes en anglais via gettext ; traduction française dans `priv/gettext/fr`. Langue : préférence du membre (`en`,
`fr`), sinon cookie `ml_locale` du sélecteur du pied de page, sinon `Accept-Language` (`MysticWeb.Locale`,
`MysticWeb.Preferences`). Dates et heures : uniquement via `MysticWeb.Format`, dans le fuseau du membre ou du
navigateur (base `tz`, `config :elixir, :time_zone_database`). Après modification des textes : `mix gettext.extract --merge`, puis compléter les `msgstr`
de `priv/gettext/fr/LC_MESSAGES/*.po`.

## Tests

`mix test` : les services sont simulés avec `Req.Test` : `stub_api/1` (`test/support/api_stub.ex`) route les
appels par `{méthode, chemin}`.
