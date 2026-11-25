# billing : crédits IA (contrat)

Registre auditable des crédits IA dépensés par le studio. Module `MlBilling.Credits`, tables `credit_accounts` (une ligne par membre, verrouillée par chaque opération) et `credit_entries` (registre en ajout seul : un déclencheur refuse toute modification ; ordre total par `seq`).

## Règles
- **Allocation mensuelle** selon la formule effective (`MlBilling.effective_plan/2`, grâce d'impayé incluse) : free **20**, premium **300**, vip **1000** par mois UTC.
- **Sans report** : à la première opération d'un nouveau mois UTC, le solde restant expire (`expiration`) puis le mois est alloué (`allocation`). Une réservation d'un mois expiré peut encore être consommée ; libérée, elle ne rend rien (`delta` 0).
- **Passage à une formule supérieure** : complément immédiat de la différence (`top_up`, une fois par mois et par formule, ref `"AAAA-MM:<plan>"`), déclenché par le changement de droits (pipeline des webhooks → `MlBilling.broadcast/1` → `Credits.sync_plan/1`) et revérifié à chaque opération. Une rétrogradation ne retire rien : elle s'applique au mois suivant.
- **Jamais de solde négatif** : chaque opération = 1 transaction avec `SELECT … FOR UPDATE` sur le compte du membre, et contrainte `balance >= 0` en base.
- **Idempotence** : unicité `(user_id, kind, ref)`. Rejouer reserve/consume/release renvoie le même état sans effet.
- **Une réservation se termine exactement une fois** : `consume` (succès) ou `release` (échec/annulation = remboursement) ; `release` après `consume` → `409 already_consumed`, `consume` après `release` → `409 already_released`.
- Après chaque opération : `{:credits_changed, user_id, balance}` publié sur `"user:<id>"`.

Ligne du registre : `{"id","kind":"allocation|top_up|reservation|consumption|release|expiration","amount" (>0, crédits concernés),"delta" (effet sur le solde disponible : + allocation/top_up/release, − reservation/expiration, 0 consumption),"balance_after","ref","reason"|null,"period":"AAAA-MM","inserted_at"}`.

## Routes

| Méthode & chemin | Jeton | Entrée | Sortie |
|---|---|---|---|
| `POST /api/internal/credits/reserve` | **service**, appelant `studio` uniquement (sinon `403 forbidden`) | `{user_id, amount (1..1000), ref ("studio:…", ≤ 120), reason? (^[a-z_]{1,40}$)}` | `200 {"ref","status":"held","amount","balance","reserved"}` (rejeu : même réponse, `status` courant) · `402 {"error":"insufficient_credits","balance"}` · 422 |
| `POST /api/internal/credits/consume` | service (studio) | `{user_id, ref}` | `200 {"ref","status":"consumed","amount","balance","reserved"}` (idempotent) · `404 not_found` (pas de réservation) · `409 already_released` · 422 |
| `POST /api/internal/credits/release` | service (studio) | `{user_id, ref}` | `200 {"ref","status":"released","amount","refunded","balance","reserved"}` (idempotent, `refunded` identique) · 404 · `409 already_consumed` · 422 |
| `GET /api/me/credits` | utilisateur | `?page=N` (20 lignes, plus récentes d'abord ; page invalide → 1) | `200 {"balance","reserved","allocation","plan","period":"AAAA-MM","resets_at":iso,"entries":[ligne],"page","total_pages","total"}` |

`ref` doit commencer par `"<service appelant>:"` (le studio utilise `"studio:gen:<uuid de génération>"`). Le `user_id` du corps n'est accepté que d'un service autorisé (jamais de `web`).
Coûts (config du studio, `config :studio, :ai_costs`) : plan 2, brouillon de leçon 5, amélioration de feedback 2, image 12 (formule VIP uniquement).
