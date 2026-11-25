# studio : MysticLore (port 4007)

Atelier de création d'aventures : projets (brief), modules et leçons dans les 3 formats corrigés par
learning (`story`, `exercise` QCM, `coding` GroveScript), collaborateurs, versions immuables, images,
générations IA payées en crédits billing, contrôles de publication, relecture par le staff et import
dans learning. Module `MlStudio` / `MlStudioWeb`, base `ml_studio_dev` / `ml_studio_test`.
Contrat : `docs/contracts/studio.md` (crédits : `docs/contracts/billing-credits.md`).

```bash
mix setup          # deps, création + migration de la base, seeds (« Le Jardin au clair de lune »)
mix phx.server     # http://localhost:4007 (le log indique le fournisseur IA)
mix test
```

## Points clés
- **Accès** : propriétaire + collaborateurs (`editor` / `viewer`) ; tout autre membre, staff compris,
  reçoit 404 sur un projet. Le staff ne voit que les versions soumises (routes `/api/moderation/*`).
- **Sauvegarde automatique** : `lock_version` par élément (brief, module, leçon) + transaction avec
  verrou de la ligne projet ; un enregistrement fait sur une version périmée reçoit `409 conflict`
  avec la version courante (l'auteur choisit). Chaque changement incrémente `content_revision`.
- **Versions** : instantanés immuables (déclencheur SQL) ; restaurer crée une nouvelle version.
- **IA** (`MlStudio.AI`) : réservation de crédits avant la mise en file (Oban `ai`), consommation au
  succès / libération à l'échec ou à l'annulation exactement une fois (Oban `credits`). Fournisseur
  DEMO (`MlStudio.AI.Deterministic`, étiqueté « DEMO MODE : not a real AI ») ou Anthropic
  (`MlStudio.AI.Anthropic`, API Messages via Req). Consentement par membre pour partager les brouillons.
- **Publication** (`MlStudio.Publishing`) : contrôles automatiques + attestations de l'auteur →
  soumission → approbation (auteur ≠ relecteur) → `ImportWorker` (Oban `publish`) → learning.
- **Images** : PNG/JPEG/WebP vérifiés par signature, ≤ 2 Mo, texte alternatif ; fichiers dans
  `STUDIO_STORAGE_DIR` (défaut dev : `priv/storage`, jamais servis statiquement).
- **Temps réel** : `"studio:project:<id>"` (`{:studio_project, …}`, `{:studio_generation, …}`).

## Variables d'environnement

| Variable | Rôle |
|---|---|
| `AI_PROVIDER` | `anthropic` ou `demo` (sinon : Anthropic si clé, DEMO hors production) |
| `ANTHROPIC_API_KEY` | active le fournisseur réel (jamais journalisée) ; absente → `503 ai_not_configured` |
| `AI_MODEL` | modèle Claude (défaut `claude-fable-5-2`) · `AI_EFFORT` (défaut `high`) · `AI_TIMEOUT_MS` (défaut 300000) |
| `STUDIO_STORAGE_DIR` | stockage privé des images et médias, chemin absolu (vide = défaut dev `priv/storage` ; obligatoire en prod : volume persistant, sinon refus de démarrer) |
| `BILLING_URL`, `ACCOUNTS_URL`, `SOCIAL_URL`, `LEARNING_URL`, `NOTIFICATIONS_URL` | services appelés (défauts locaux) |
| `INTERNAL_SECRET`, `DB_*`, `PORT` ; prod : `DATABASE_URL`, `SECRET_KEY_BASE` | communs |

Coûts (`config :studio, :ai_costs`) : plan 2, brouillon de leçon 5, amélioration de feedback 2, image 12 (VIP).
