# billing : MysticLore (port 4003)

Formules, checkout, abonnements, webhooks et droits. Module `MlBilling` / `MlBillingWeb`, base
`ml_billing_dev` / `ml_billing_test`. Contrat : `docs/CONTRACTS.md` (section billing).

```bash
mix setup          # deps, création + migration de la base, seeds
mix phx.server     # http://localhost:4003 (le log indique le mode : stripe | local | disabled)
mix test
```

## Règle d'or

Les droits ne changent **que** par des événements de webhook **signés** (Stripe, ou le fournisseur
local DEMO), traités par un pipeline unique (`MlBilling.Webhooks`). Une URL de retour de checkout
n'active jamais rien : `web` affiche « en attente » en lisant `GET /api/checkout/:id` et se met à
jour sur `{:entitlements_changed, user_id, plan}` (topics `"entitlements"` et `"user:<id>"`).
Aucune donnée de carte n'est reçue ni stockée (paiement sur Stripe Checkout, hébergé par Stripe).

## Modes

| Mode | Condition | Effet |
|---|---|---|
| `stripe` | `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_PREMIUM`, `STRIPE_PRICE_VIP` définis | vrai Stripe Checkout (mode subscription), Customer Portal, webhooks |
| `local` (DEMO) | sinon, si `BILLING_LOCAL_MODE` ≠ `false` (défaut en dev/test) ; **en prod uniquement avec `BILLING_LOCAL_MODE=true` explicite** | paiement simulé, aucun argent |
| `disabled` | sinon | `POST /api/checkout` → `503 payments_disabled` |

## Variables d'environnement

| Variable | Rôle |
|---|---|
| `STRIPE_SECRET_KEY` | clé API (`sk_test_…` en test), envoyée en Bearer à `api.stripe.com` uniquement |
| `STRIPE_WEBHOOK_SECRET` | secret `whsec_…` de l'endpoint (ou affiché par `stripe listen`) |
| `STRIPE_PRICE_PREMIUM`, `STRIPE_PRICE_VIP` | ids de prix mensuels ; servent aussi à retrouver la formule d'un abonnement reçu |
| `BILLING_LOCAL_MODE` | `false` désactive le mode local ; `true` obligatoire pour l'autoriser en prod |
| `BILLING_LOCAL_WEBHOOK_SECRET` | secret de signature du mode local (défaut : dérivé de `INTERNAL_SECRET` par HMAC) |
| `INTERNAL_SECRET` | jeton interne partagé (prod) ; `DB_USER`/`DB_PASSWORD`/`DB_HOST`, `PORT` ; prod : `DATABASE_URL`, `SECRET_KEY_BASE` |
| `NOTIFICATIONS_URL` | centre de notifications (défaut `http://localhost:4008`) : changements d'abonnement notifiés par Oban (`MlBilling.Notices`) |

Formules et prix de démo : `config :billing, :plans` (free 0, premium 1200, vip 2400 USD/mois).

## Pipeline des webhooks (`MlBilling.Webhooks`)

1. Vérification `Stripe-Signature` (`t=…,v1=…`, HMAC-SHA256 de `"<t>.<corps brut>"`, tolérance 300 s,
   comparaison en temps constant, plusieurs `v1` acceptés) → sinon `400 invalid_signature`.
   Le corps brut de `POST /webhooks/stripe` est conservé par `MlBillingWeb.BodyReader` (ce chemin seulement).
2. Déduplication : insertion dans `webhook_events` avec `ON CONFLICT DO NOTHING` sur
   `(provider, provider_event_id)` → un doublon (même en parallèle) n'a aucun effet (`200 {"status":"duplicate"}`).
3. Transaction + `SELECT … FOR UPDATE` sur la ligne d'abonnement de l'utilisateur (créée en
   `status: "none"` si absente, pour sérialiser aussi la première activation).
4. Événement plus ancien que `last_event_at` → enregistré `stale`, sans effet.
5. Après commit : publication `{:entitlements_changed, user_id, plan}`.

Événements gérés : `checkout.session.completed` (session → `completed`),
`customer.subscription.created|updated|deleted` (formule via l'id de prix, statut, période,
`cancel_at_period_end`), `invoice.paid` / `invoice.payment_failed` (facture `paid|failed` ;
`past_due` ↔ `active` de l'abonnement courant). Autres types : `200 {"status":"ignored"}`.
Erreur métier permanente (utilisateur ou prix inconnu) : `200 {"status":"failed"}` + colonne `error`.
Les données personnelles du client (`customer_details`, `customer_email`…) ne sont pas conservées dans `payload`.

Droits (`MlBilling.effective_plan/2`) : `active` → formule (jusqu'à `current_period_end` si
`cancel_at_period_end`) ; `past_due` → formule pendant 3 jours après le premier échec, puis `free` ;
`canceled` / `none` / pas d'abonnement → `free`.

## Mode local (DEMO)

1. `POST /api/checkout` → session locale (1 h) → `url = "/membership/local-checkout/<session_id>"` (page de `web`).
2. `POST /api/checkout/:id/simulate-payment {"outcome":"succeeded"}` (propriétaire seulement, sinon 404) :
   construit `checkout.session.completed`, `customer.subscription.created` (période = 1 mois) et
   `invoice.paid` au format Stripe, les **signe** avec le secret local et les passe à
   `Webhooks.handle("local", corps, signature)` : même pipeline, signature vérifiée. Traitement
   synchrone, réponse `202`. Ids d'événements dérivés de la session : rejouer est sans effet.
   `{"outcome":"failed"}` → `invoice.payment_failed` : facture `failed`, rien n'est accordé, la session reste ouverte.
3. Résiliation / reprise : événement `customer.subscription.updated` signé.
4. `MlBilling.PeriodEndWorker` (Oban, queue `default`, cron `*/15 * * * *`) : pour les abonnements
   locaux dont la période est échue, `customer.subscription.deleted` si `cancel_at_period_end`
   (→ `canceled`, `free`), sinon renouvellement d'un mois (`invoice.paid` + `customer.subscription.updated`),
   comme le ferait Stripe. En mode Stripe, c'est Stripe qui envoie ces événements.

## Tester Stripe en mode test

1. Compte Stripe en **mode test** → Developers → API keys : `sk_test_…`.
2. Deux prix mensuels récurrents (Dashboard → Product catalog, ou Stripe CLI) :
   ```bash
   stripe prices create --currency usd --unit-amount 1200 -d "recurring[interval]=month" -d "product_data[name]=MysticLore Premium"
   stripe prices create --currency usd --unit-amount 2400 -d "recurring[interval]=month" -d "product_data[name]=MysticLore VIP"
   ```
3. Customer Portal : Settings → Billing → Customer portal → l'activer une fois en mode test
   (sinon `POST /v1/billing_portal/sessions` est refusé ; l'API renvoie alors `502 provider_error`).
4. Relayer les webhooks vers le service (affiche le secret `whsec_…`) :
   ```bash
   stripe login
   stripe listen --forward-to localhost:4003/webhooks/stripe \
     --events checkout.session.completed,customer.subscription.created,customer.subscription.updated,customer.subscription.deleted,invoice.paid,invoice.payment_failed
   ```
5. Démarrer billing en mode Stripe :
   ```bash
   STRIPE_SECRET_KEY=sk_test_… STRIPE_WEBHOOK_SECRET=whsec_… \
   STRIPE_PRICE_PREMIUM=price_… STRIPE_PRICE_VIP=price_… mix phx.server   # log : "billing payment mode: stripe"
   ```
6. Depuis `web` (`/membership`) choisir une formule → page Stripe Checkout → carte
   **4242 4242 4242 4242**, date d'expiration future quelconque, CVC quelconque. Le retour sur
   `success_url` affiche « en attente » jusqu'aux webhooks (`stripe listen` les montre), puis la
   formule devient active. Carte refusée : 4000 0000 0000 9995. Résiliation / reprise :
   `POST /api/me/subscription/{cancel,resume}` (appel `POST /v1/subscriptions/:id cancel_at_period_end`),
   ou le portail (`POST /api/portal`).
   `stripe trigger …` crée des clients inconnus du service : ces événements sont acquittés en `failed` (`unknown_user`).

Appel manuel d'une route interne en dev (jeton signé comme `web`, utilisateur de démo `hugo_bernard`) :
```bash
TOKEN=$(mix run --no-start -e 'Application.ensure_all_started(:plug_crypto); IO.puts MlShared.InternalToken.sign("web", "00000000-0000-4000-8000-000000000002")')
curl -s -H "authorization: Bearer $TOKEN" -H "content-type: application/json" localhost:4003/api/checkout \
  -d '{"plan":"premium","success_url":"http://localhost:4000/membership/success?session_id={CHECKOUT_SESSION_ID}","cancel_url":"http://localhost:4000/membership/cancel"}'
```

## Précisions sur le contrat

- `success_url` / `cancel_url` sont obligatoires (URL http(s) absolues) ; `{CHECKOUT_SESSION_ID}` y est
  remplacé par le `session_id` renvoyé (UUID de billing, identique dans les deux modes).
- Changement de formule : nouveau checkout autorisé si la formule diffère (`409 already_subscribed`
  si même formule active) ; à l'activation le nouvel abonnement remplace l'ancien ; en mode Stripe,
  l'ancien est résilié chez Stripe (`MlBilling.StripeCancelWorker`, `prorate=true`) pour ne jamais facturer deux fois.
- Erreurs ajoutées : `409 checkout_completed|checkout_expired` (simulate-payment), `502 provider_error`
  (Stripe injoignable ou en erreur), `404` pour cancel/resume sans abonnement en cours, `400 invalid_payload`
  (webhook signé mais illisible).
- Résiliation/reprise en mode Stripe : le drapeau `cancel_at_period_end` renvoyé par l'API Stripe est
  appliqué immédiatement (aucun changement de formule) ; le webhook `customer.subscription.updated` suit.

## Seeds

`priv/repo/seeds.exs` (idempotent, UUID de `MlShared.Demo`, dates relatives) : `lea_moreau`
Premium actif (renouvellement dans 20 jours), `ines_petit` VIP actif résilié en fin de période
(dans 5 jours), 3 factures payées fictives. Refusé en prod.

## Crédits IA (`MlBilling.Credits`, contrat `docs/contracts/billing-credits.md`)

Registre en ajout seul (`credit_entries`, déclencheur anti-modification, ordre `seq`) + une ligne de
compte par membre (`credit_accounts`, `SELECT … FOR UPDATE` à chaque opération, `balance >= 0`).
Allocation mensuelle selon la formule effective (free 20, premium 300, vip 1000), expiration du reste
au changement de mois UTC, complément immédiat au passage à une formule supérieure (déclenché aussi par
`MlBilling.broadcast/1` après chaque changement de droits), idempotence `(user_id, kind, ref)`.
Routes : `POST /api/internal/credits/reserve|consume|release` (service `studio` uniquement),
`GET /api/me/credits`. Les seeds ajoutent l'historique de Léa et Inès (références des générations
de démo du studio).
