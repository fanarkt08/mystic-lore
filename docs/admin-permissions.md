# Matrice des droits : administration & modération

Rôles : **user** (membre), **moderator**, **admin** (stockés dans accounts, `users.role`). Le rôle n'a aucun lien avec la
formule d'abonnement (un VIP reste `user`). Chaque service vérifie le rôle **côté serveur** à chaque requête (lu chez
accounts, cache court invalidé par l'événement `"members"`) ; l'interface web le vérifie aussi au montage et à chaque
événement, mais n'accorde jamais rien seule. Routes : [docs/contracts/admin.md](contracts/admin.md).

| Capacité | user | moderator | admin | Où c'est appliqué |
|---|:---:|:---:|:---:|---|
| Voir l'entrée « Administration » et `/admin` (indicateurs) | 403 | ✓ (sans les chiffres de facturation) | ✓ | web `Admin.Guard` ; chaque service `GET /api/admin/stats` |
| Indicateurs de facturation (abonnements, revenus, webhooks) | - | - | ✓ | billing (admin) |
| File des signalements (messages, membres, joueurs, forum) | 403 | ✓ | ✓ | social, community |
| Lire la preuve d'un message signalé (instantané seul, motif ≥ 10 car., audit écrit avant) | 403 | ✓ | ✓ | social |
| Ouvrir la pièce jointe d'un message signalé (motif ≥ 10 car., audit `social.report.attachment_viewed` écrit avant ; aussi après un retrait) | 403 | ✓ | ✓ | social |
| Lire une conversation privée | membres de la conversation seulement | ✗ | ✗ | social (aucune route staff) |
| Résoudre : classer, retirer le message, masquer / retirer un post | 403 | ✓ | ✓ | social, community |
| Avertir, restreindre (1 h à 30 j, motif), lever une sanction | 403 | ✓ (membres `user` seulement) | ✓ (membres `user` seulement) | accounts |
| Se sanctionner soi-même, sanctionner un membre du staff | - | ✗ | ✗ | accounts (`self`, `staff_target`) |
| Trancher un appel | 403 | ✓ sauf sur ses propres sanctions | ✓ sauf sur ses propres sanctions | accounts (`same_staff`) |
| Voir ses propres sanctions, faire appel (un appel ouvert par sanction) | ✓ | ✓ | ✓ | accounts `/api/me/sanctions` |
| Membres : liste, fiche, état, suppression programmée | 403 | ✓ (e-mail masqué) | ✓ (e-mail complet, consultation auditée) | accounts |
| Réinitialiser l'avatar d'un membre (motif 5–500 car., audité `accounts.avatar.reset`) | 403 | ✓ | ✓ | accounts (`POST /api/admin/users/:id/avatar/reset`) |
| Changer un rôle | 403 | 403 | ✓ (jamais le sien, jamais le dernier admin) | accounts (verrou sur les lignes admin) |
| Incidents : ouvrir, chronologie, résoudre (résumé obligatoire) | 403 | ✓ | ✓ | accounts |
| File de relecture du studio | 403 | ✓ (pas ses propres projets) | ✓ (pas ses propres projets) | studio |
| Journal d'audit : lecture, filtres, export CSV (audité) | 403 | 403 | ✓ | accounts |
| Abonnements et webhooks en échec (lecture seule) | 403 | 403 | ✓ | billing |
| Ajustement manuel de crédits IA (motif, ref unique, audité) | 403 | 403 | ✓ | billing |
| Modifier le statut d'un abonnement | ✗ | ✗ | ✗ | aucune route (seuls les webhooks signés) |
| Écrire dans le journal d'audit | ✗ | ✗ | ✗ | jeton de **service** des services backend seulement (`web` refusé) |

Effet d'une **restriction** active (`restricted_until` dans le futur) : le membre lit, apprend et joue, mais
`403 restricted` (avec la date de fin) sur l'envoi de message privé (social), la création / réponse / édition au forum
(community) et le chat d'un salon (multiplayer). accounts injoignable : ces écritures sont refusées (503), jamais
autorisées par défaut.

Toute action du staff écrit une entrée dans le journal central (`audit_entries`, ajout seul), dans la transaction de
l'action ; si l'entrée ne peut pas être écrite, l'action n'a pas lieu (`503 audit_unavailable`).
