# Suppression de compte : politique par service

Ce que devient chaque donnée quand la suppression d'un compte est exécutée (à l'échéance du délai de grâce,
`ACCOUNT_DELETION_GRACE_DAYS`, 30 jours par défaut). Routes et orchestration : [docs/contracts/privacy.md](contracts/privacy.md).

Principe : les **données personnelles** sont supprimées ; les **contributions** visibles par d'autres membres sont
conservées, rattachées à l'identifiant du compte, qui s'affiche désormais « Deleted member » (accounts anonymise la
ligne du membre : tous les services qui enrichissent leurs auteurs par `GET /api/users?ids=` l'affichent sans
modification) ; ce que la loi impose de garder (facturation) l'est **sans donnée personnelle** ; signalements et
journaux de modération restent pour la sécurité des autres membres.

Ordre d'exécution : multiplayer → studio → community → social → billing → learning → notifications → accounts
(anonymisation). Le centre de notifications passe en dernier : aucune étape précédente ne peut plus lui en créer.
Chaque `DELETE /api/internal/users/:id` est idempotent ; une étape réussie n'est jamais rejouée.

| Service | Supprimé | Conservé, anonymisé (« Deleted member ») | Conservé (obligation, sécurité) |
|---|---|---|---|
| **accounts** | e-mail, pseudonyme, nom affiché, bio (remplacés) ; pronoms, centres d'intérêt, couverture, avatar (fichier de l'image supprimé de `ACCOUNTS_STORAGE_DIR`), préférences (remises par défaut) ; mot de passe (rendu inutilisable) ; secrets 2FA et codes de récupération ; sessions, challenges, jetons d'e-mail ; exports ; **demandes de support et réponses du staff** ([support](contracts/support.md)) ; compteurs de limitation et échecs de connexion | l'identifiant (UUID), le rôle ramené à `user`, les dates d'inscription/confirmation, la date de suppression | `deletion_steps` (trace de l'exécution, sans donnée personnelle) |
| **learning** | inscriptions, progression des leçons (notes et brouillons compris), XP, badges, reçus des actions hors ligne synchronisées | - | aventures publiées depuis le studio : restent au catalogue avec `author_id` nul |
| **billing** | lien d'hébergement des factures (`hosted_url`), contenu brut des webhooks reçus pour le membre (peut contenir nom, e-mail, adresse) | - | abonnement **résilié immédiatement** (en mode Stripe : `DELETE /v1/subscriptions/:id` chez Stripe, au prorata ; checkouts Stripe ouverts expirés) puis ligne `canceled` (formule gratuite) ; **factures** (montant, devise, période, identifiants du fournisseur) et **registre de crédits IA** (ajout seul) conservés pour obligation comptable |
| **social** | amitiés, demandes d'ami (envoyées et reçues), blocages (dans les deux sens), réglages de confidentialité, appartenances aux conversations (dates de lecture, sourdine), **fichiers de ses pièces jointes** (effacés de `SOCIAL_STORAGE_DIR` après l'écriture en base) ; il quitte ses groupes (propriété au plus ancien, groupe vide supprimé) | messages envoyés (la conversation reste lisible par les autres membres ; une pièce jointe effacée apparaît « supprimée ») | signalements déposés par le membre ou le visant (instantanés compris) |
| **multiplayer** | invitations (envoyées et reçues), liens d'invitation créés, récompenses d'XP en attente ou livrées | messages du chat des salons, salons fermés qu'il a hébergés, historique des parties (journal, participations) ; le membre **quitte** ses salons ouverts par le chemin normal (hôte transféré au plus ancien membre, salon vide fermé, partie poursuivie ou interrompue) | - |
| **community** | abonnements aux discussions (suivis) | discussions et réponses (tous statuts), votes « utile » (compteurs inchangés) | signalements déposés, journal de modération (y compris ses actions de modérateur) |
| **studio** | projets possédés **sans collaborateur et jamais publiés** (contenu, versions, images et fichiers) ; ses collaborations sur les projets des autres ; ses générations IA (après clôture de leurs réservations de crédits chez billing) ; ses préférences IA | projets **collaboratifs ou publiés** : conservés avec `owner_id` nul (les collaborateurs continuent ; personne ne peut plus les soumettre ni gérer les collaborateurs) ; versions et images qu'il a ajoutées aux projets conservés | - |
| **notifications** | notifications **reçues** par le membre, ses préférences par canal et ses heures calmes (avec leur fuseau), ses e-mails reportés, le journal de ses e-mails (limite de débit), les occurrences traitées et marques de lecture, ses tâches d'e-mail et de résumé en attente (annulées) ; aucune adresse e-mail n'y a jamais été stockée | notifications dont il est l'**acteur**, reçues par d'autres membres : conservées chez leurs destinataires (identifiants et titres publics seulement), son nom s'y affiche « Deleted member » | - |

## Garanties et limites
- **Pendant le délai** : rien n'est supprimé ; le membre se reconnecte et annule depuis le tableau de bord ou les
  paramètres. **À l'échéance** : connexion refusée, puis exécution ; si un service est indisponible, l'exécution
  s'arrête à cette étape et reprend plus tard (backoff borné, balayage toutes les 5 minutes), sans rejouer les étapes
  faites. Le compte n'est anonymisé qu'une fois toutes les étapes réussies.
- **Crédits IA** : studio libère (ou consomme, si la génération avait réussi) chaque réservation ouverte avant de
  supprimer les générations ; billing injoignable → `503 credits_unavailable`, rien n'est supprimé, nouvel essai.
- **Stripe** : l'abonnement est annulé chez Stripe et les checkouts ouverts expirés ; l'objet « customer » Stripe
  (e-mail) n'est pas supprimé par l'application (à purger depuis le tableau de bord Stripe si nécessaire). Stripe
  injoignable → `503 provider_error`, nouvel essai : le membre ne peut plus être débité.
- Une récompense d'XP déjà en cours d'envoi au moment de l'étape multiplayer peut encore être créée chez learning ;
  l'étape learning, exécutée après, l'efface (fenêtre de l'ordre de la seconde).
- Les autres services ne gardent pas de liste des comptes supprimés : un appel interne direct par identifiant (ex.
  demande d'ami) reste techniquement possible, mais aucune interface ne mène plus au compte (profil 404, absent de la
  recherche).
- Les exports (données complètes) sont stockés en base accounts au plus 24 h après leur fin, puis purgés.
- Demandes de support : celles d'un membre partent avec son compte ; celles d'un visiteur (sans compte)
  sont supprimées par la rétention (180 jours après la clôture, 365 jours sans activité) ; un visiteur qui veut les
  faire effacer plus tôt le demande (formulaire de contact) et un admin les efface aussitôt depuis `/admin/support`
  (`DELETE /api/admin/support/requests/:id`, audité sans le texte).

- Leçons hors ligne : les copies et les réponses en attente sont dans le navigateur du membre, hors de
  portée des serveurs. La suppression du compte révoque ses sessions ; un appareil qui ne se reconnecte pas garde ses
  copies jusqu'à leur expiration (14 jours au plus, jamais après la fin de la période payée : l'abonnement étant
  résilié, aucun nouveau téléchargement n'est possible) ; une synchronisation ultérieure est refusée (session).

- Une notification « au mieux » (social, community, multiplayer, learning) encore en route vers le centre au moment de
  l'étape `notifications` peut y arriver juste après : elle ne contient que des identifiants et sera purgée par la
  rétention (90 jours) ; aucun e-mail ne part pour un compte supprimé (accounts refuse : `409 not_deliverable`).

## Vérification réelle (pile `bin/dev`)
`e2e/privacy_smoke.exs` (nœud du cluster, deux membres jetables A et B, jamais de compte de démo) : activité dans les
7 services (8 : le centre de notifications), routes internes refusées à un autre appelant (403),
export assemblé en tâche de fond (événement temps réel reçu) puis téléchargé par web (≈ 16 Ko, 8 sections, aucun
message ni aucune notification de B), IDOR refusé, suppression programmée (J+30,
sessions révoquées, e-mail), connexion pendant le délai, annulation, puis échéance mise dans le passé en base de dev et
exécuteur déclenché : **15/15 vérifications OK** (trois exécutions). Contrôle en base ensuite : learning 0 ligne
(inscriptions, progression, XP, badges) ; social 0 amitié/blocage, messages de A et B conservés ; multiplayer A `left`,
hôte transféré à B, 0 invitation/lien/récompense, message conservé ; community 0 suivi, discussion conservée ; studio
0 projet possédé, brouillon solo supprimé, projet partagé conservé sans propriétaire avec B éditeur, 0 génération ;
billing abonnement `canceled`, facture conservée sans lien, registre de crédits conservé, webhooks vidés ; accounts
ligne anonymisée, 0 session/export/jeton/compteur, 7 étapes ; connexion refusée.
`privacy_smoke.exs` vérifie aussi la section `notifications` de l'export (notifications reçues par A seulement) et, après
la suppression, 0 notification pour A et, chez B, celles dont A était l'acteur affichées « Deleted member » : 16/16.
