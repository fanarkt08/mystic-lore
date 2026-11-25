# Limites connues

Les tests automatisés ne remplacent pas un audit de sécurité. Les limites propres à chaque service sont détaillées dans son README et son contrat.

## Non vérifié dans cet environnement
- **API Stripe et Anthropic réelles** : uniquement par stubs `Req.Test` et webhooks signés localement. Il faut vos clés de test, voir `src/billing/README.md` et `.env.example`.
- **Docker et Compose** : en production sur un serveur Hetzner depuis le 25/11/2026, derrière Caddy (HTTPS). Le moteur
  natif Rust n'est pas compilé dans les images : les simulations y tournent avec l'implémentation Elixir. Aucun
  fournisseur d'e-mails n'est encore branché en production. La CI GitHub est écrite mais pas encore exécutée.
- **Maquettes Figma** : les illustrations de l'accueil et des aventures en sont tirées ; les versions mobiles n'ont été
  revues que sur la navigation (voir [docs/wireframes](wireframes/README.md)).
- **Accessibilité** : voir la section « Accessibilité » ci-dessous. Aucune conformité WCAG n'est
  revendiquée : ce qui est vérifié l'est automatiquement ou par script, dans Chrome seulement, jamais avec une
  technologie d'assistance.
- **Traduction française** : non relue par un locuteur natif ; quelques textes récents de l'interface restent en
  anglais tant qu'ils ne sont pas extraits et traduits (`ALLOW_PENDING=1 node e2e/i18n.mjs` en donne la liste). Les contenus des services et des membres
  (aventures, chapitres, leçons, objectifs, indices et choix des quiz, libellés des paramètres de simulation, quêtes et
  badges de learning, titres et textes du forum, messages, projets du studio) ne passent pas par l'interface : les
  contenus de démonstration sont écrits en français et s'affichent tels quels dans
  les deux langues (listés à part par `e2e/i18n.mjs`). Les simulations s'affichent dans la langue du membre :
  web recompose la description et nomme les colonnes à partir des chiffres de learning, et traduit le retour
  de correction d'après son `feedback_code` (voir `docs/contracts/learning-formats.md`). Restent en anglais les **retours
  calculés par learning** des exercices de code GroveScript et des mini-jeux (il leur faudrait le même code et ses
  paramètres dans l'API). La vidéo de démonstration a des titres incrustés en français (`e2e/tools/make_lesson_video.mjs`). Les e-mails du centre de notifications et du support sont rédigés par accounts en
  anglais et en français (textes écrits directement dans `MlAccounts.NotificationEmail` et `MlAccounts.SupportEmail`,
  non relus).

## Limites fonctionnelles et techniques
- **Temps réel** : il repose sur le cluster Erlang (`CLUSTER_NODES`, liste statique, ou `bin/dev`). Sur plusieurs machines, il faut une découverte des nœuds (DNS, libcluster) et un cookie secret.
- **Multijoueur** :
  - un seul nœud multiplayer est supposé (Registry local) ;
  - pas de minuteur de tour ;
  - la liste des salons se rafraîchit à la demande ;
  - les états de connexion ont jusqu'à 5 s de retard.
- **Formats de leçon** :
  - vidéo : le serveur ne vérifie pas le visionnage réel (part lue déclarée par le navigateur, ou transcription ouverte) ;
  - médias du studio relayés entiers par web (pas de requêtes partielles ; jusqu'à 50 Mo en mémoire par requête) ;
  - vidéo de démonstration produite sans ffmpeg (MediaRecorder de Chrome) : durée écrite après coup, pas d'index de
    recherche (`Cues`) ;
  - formules chimiques sans parenthèses ; un seul couple de paramètres réglables pour `orbit` dans le studio ;
  - l'IA du studio ne rédige pas ces formats (médias ou modèle requis).
- **Studio** :
  - génération d'images en démo uniquement ;
  - restaurer une version crée de nouveaux identifiants de leçons ;
  - un projet conservé sans propriétaire (après suppression de compte) ne peut plus être soumis.
- **Billing** :
  - l'état `past_due` n'est pas atteignable en mode simulé ;
  - en mode Stripe, la perte d'un événement `customer.subscription.deleted` laisserait des droits ;
  - l'objet `customer` Stripe n'est pas supprimé à la suppression du compte.
- **Données personnelles** :
  - suppression bloquée (relancée indéfiniment) tant que billing ou Stripe est indisponible ;
  - exports stockés en clair dans la base accounts pendant 24 h au plus ;
  - téléchargement limité par le délai du client interne (5 s).
- **Sécurité** :
  - limites de débit web en mémoire, par nœud ; relâchées en dev ;
  - derrière un proxy, l'IP doit venir d'un en-tête de confiance ;
  - pas de récupération par l'équipe si un membre perd téléphone ET codes de secours ;
  - réponse de « mot de passe oublié » synchrone (différence de temps possible).
- **Social** ([contrat](contracts/social.md)) :
  - pas de chiffrement de bout en bout (indiqué dans l'interface) ; les messages sont lisibles en base par l'exploitant ;
  - limite de débit des messages (20 / 10 s, 300 / h par membre) en fenêtres fixes et en ETS **par nœud** : avec
    plusieurs nœuds social, chacun compte de son côté ; jusqu'à 40 messages peuvent passer à cheval sur deux fenêtres de
    10 s ;
  - antivirus : seul l'adaptateur clamd existe et il n'a été testé que contre un faux serveur TCP (aucun ClamAV installé
    ici) ; sans `CLAMD_HOST`, les fichiers sont acceptés « non analysés » (affiché tel quel) ;
  - PDF gardés tels quels (ni nettoyés, ni rendus) : toujours servis en téléchargement, jamais affichés dans la page ;
    images : mêmes limites que les avatars (pixels non décodés, orientation EXIF perdue, WebP animé accepté) ;
  - pièces jointes envoyées en Base64 dans le JSON interne (environ +33 %) et relayées entières par web (jusqu'à 10 Mo
    en mémoire par requête) ; l'export de données les contient aussi en Base64 (exports volumineux, délai de 30 s par
    service) ;
  - le fichier d'un message retiré par la modération est gardé pour la preuve auditée et les appels (inaccessible aux
    membres) ; un groupe vide est supprimé avec ses fichiers, même si un signalement ouvert les citait (l'instantané du
    texte reste) ;
  - statut en ligne : `Phoenix.Presence` sur un topic global (chaque page qui l'affiche reçoit tous les changements ;
    à grande échelle, un topic par ami serait préférable) ; il suit les pages ouvertes, pas l'activité réelle ;
  - sourdine : aucune notification à son échéance (le badge se corrige au rechargement suivant) ; pendant une
    sourdine, aucun message ne crée de notification (elle ne rattrape pas les messages reçus pendant la sourdine) ;
  - accusés de lecture : la date de lecture est celle de la dernière ouverture de la conversation (pas message par
    message) ; « Seen » n'est montré que sous mon dernier message s'il est le plus récent du fil ;
  - les événements de messagerie sont livrés sur `"user:<id>"`, auquel d'autres services peuvent être abonnés (le cache
    de community les reçoit et les ignore) ;
  - une conversation directe n'est pas filtrée après un blocage (elle reste lisible, l'envoi est refusé) ; seuls les
    groupes masquent les messages.
- **Administration** :
  - en dev, `debug_errors` affiche la page Plug.Debugger au lieu de la page 403 thématique (le statut 403 est bien renvoyé) ;
  - seuls les signalements forum ouverts sont listés.
- **Paramètres et profil** :
  - avatar : structure vérifiée et métadonnées retirées en Elixir pur, mais les pixels ne sont ni décodés ni ré-encodés
    (une image structurellement valide aux données corrompues est acceptée et ne s'affichera pas) ; l'orientation EXIF
    disparaît avec l'EXIF (une photo de téléphone peut apparaître tournée) ; le profil de couleur ICC des JPEG est retiré ;
    un WebP animé est accepté tel quel ; après une réinitialisation, une copie peut rester jusqu'à 1 jour dans le cache
    d'un navigateur qui l'avait chargée (l'URL n'est plus référencée ni servie) ;
  - fuseau `auto` : connu seulement une fois la page connectée (LiveSocket) ; le premier rendu HTML et les pages servies
    par un contrôleur (connexion, inscription, mot de passe oublié) affichent l'UTC ; la liste du sélecteur est une
    sélection de fuseaux courants (l'API accepte tout nom IANA, et le fuseau détecté est ajouté) ;
  - le « jour de l'académie » (quêtes, série, graphique des 7 jours, objectif quotidien) reste le jour UTC de learning ;
    son renouvellement est affiché à l'heure locale du membre ;
  - thème VIP : la formule est redemandée à billing à chaque page pour les membres qui ont choisi un thème VIP (un appel
    de plus) ; billing injoignable → thème mis en pause ;
  - langue : les pages servies par un contrôleur suivent le visiteur (cookie, `Accept-Language`), pas la préférence d'un
    membre connecté ;
  - les illustrations de couverture restent sombres dans tous les thèmes ; les libellés de la barre mobile et du graphique
    des 7 jours sont plafonnés à 12 px quand le texte est agrandi ;
  - les réglages de notifications sont ceux du centre (`/settings/notifications`) ; la section « Privacy »
    reste celle des permissions de contact (social).
- **Centre de notifications** ([contrat](contracts/notifications.md)) :
  - **voie « au mieux »** (social, community, multiplayer, learning, sans Oban) : tâche en mémoire avec 6 essais en
    environ 52 s ; une notification est perdue si son nœud s'arrête pendant ce temps ou si le centre reste injoignable
    plus longtemps (journalisé, sans contenu). L'action d'origine (message, réponse, invitation, badge) n'est jamais
    affectée. accounts, billing et studio passent par Oban (durable), mais accounts insère la tâche juste après l'action :
    une base indisponible à cet instant précis perd la notification (journalisé) ;
  - une lecture par clé (conversation lue) et la création de la notification d'un message se croisent sans dommage
    (marque de lecture, 7 jours) ; au-delà de 7 jours, une création très en retard redeviendrait non lue ;
  - pas de notification au navigateur ni au téléphone (Web Push) : la cloche et le toast n'existent que sur les pages
    ouvertes ; le toast n'est montré que par les pages ouvertes au moment de l'événement (8 s) ;
  - heures relatives (« 5 min ago ») recalculées à chaque rendu de la page, pas à la minute ;
  - heures calmes : un seul créneau quotidien, le même chaque jour ; le fuseau est celui de la page au moment de
    l'enregistrement (préférence explicite, ou fuseau du navigateur si elle vaut `auto`) : changer de fuseau ensuite ne
    les déplace pas tant qu'elles ne sont pas réenregistrées (la page le signale) ; sans fuseau connu, elles ne
    s'appliquent pas ; un fuseau inconnu de la base embarquée `tz` est refusé ;
  - pendant les heures calmes, le bandeau de la discussion ouverte (forum) et les messages qui arrivent dans la
    conversation ouverte restent affichés : c'est le contenu de la page, pas une notification ;
  - e-mails : langue `en`/`fr` du membre, **anglais si sa langue vaut `auto`** (accounts ne connaît pas la langue du
    navigateur) ; un e-mail facultatif part après un délai (60 s, 10 s en dev) et seulement si la notification n'a pas
    été lue entre-temps ; limite d'un e-mail par clé (conversation, discussion…) et par heure et de 20 par jour et par
    membre (hors sécurité) : au-delà, rien n'est rattrapé par e-mail (l'entrée in-app reste) ; le résumé de fin d'heures
    calmes liste 20 éléments au plus (« et N autres ») et omet ce qui a été lu entre-temps ; un résumé perdu (accounts
    injoignable pendant 8 essais) est abandonné ; aucun lien de désinscription en un clic (le lien mène aux réglages) ;
  - l'export de données prêt est signalé in-app seulement (pas d'e-mail) ; un e-mail n'est jamais envoyé pour une
    sorte dont accounts envoie déjà le sien (changement d'adresse, sanctions, appels) ;
  - rétention : 90 jours après le dernier événement, 500 notifications par membre ; pas d'archive au-delà ;
  - les notifications du studio ne portent que l'identifiant du projet : la page relit chez studio le titre et le motif
    de chaque décision affichée (un appel par projet de la page) ; projet supprimé ou accès perdu → texte générique ;
  - l'agrégation garde l'acteur et les paramètres du dernier événement reçu (un événement plus ancien arrivé en retard
    peut les remplacer) ;
  - effacement entre deux membres (blocage) : supprime aussi une notification de groupe dont le membre bloqué était le
    dernier auteur (elle peut regrouper des messages d'autres membres ; leurs messages restent dans la conversation) ;
  - lever un blocage ne restaure rien ; une notification déjà affichée en toast ne disparaît qu'à la fermeture ou après
    8 s.
- **Aide, contact, pages juridiques et accueil guidé** :
  - **pages juridiques** : textes provisoires, jamais relus par un juriste ; l'identité de l'exploitant, les bases
    légales, la durée des journaux du serveur et du journal d'audit, le fournisseur d'e-mail, l'hébergeur, l'âge minimal,
    les règles de remboursement et l'autorité compétente sont des emplacements « à compléter par l'exploitant » ;
    aucune conformité (RGPD, WCAG) n'est revendiquée. L'état des sous-traitants affiché est celui de ce serveur : le
    mode de paiement d'après billing, le fournisseur d'IA seulement pour un membre connecté (la route de studio exige
    un membre) ; le fournisseur d'e-mail ne se configure qu'en modifiant `runtime.exs` d'accounts (aucun n'est livré) ;
  - **contact et support** : limite par IP en mémoire et par nœud web (comme les autres limites de web ; derrière un
    proxy, l'IP doit venir d'un en-tête de confiance) ; le champ piège n'arrête pas un robot qui lit le CSS (pas de
    CAPTCHA : les limites par IP, par compte et par adresse restent la vraie barrière) ; pas de pièce jointe ni de fil
    de discussion (le demandeur réécrit avec sa référence) ; les e-mails du support (anglais, français) ne sont pas
    relus ; les demandes d'un visiteur ne s'effacent avant la rétention que par un admin (`/admin/support`) ; aucun
    délai de réponse n'est promis ni mesuré ;
  - **accueil guidé** : il reste proposé à chaque connexion tant qu'il n'a été ni terminé ni passé (fermer l'onglet en
    cours de route ne compte pas) ; `/welcome` reste ouvert à tout membre, même après la fin ;
  - **retour après connexion** : la page à retrouver n'est connue qu'au premier rendu HTTP d'une page ; une LiveView
    montée par une navigation en direct, puis refusée, renvoie vers le tableau de bord après la connexion ;
  - **accès Premium terminé** : la date affichée est la fin de période donnée par billing quand elle est passée ; une
    résiliation immédiate (Stripe) ou la fin d'une grâce d'impayé s'affichent « has ended » sans date. Le basculement
    en direct d'une leçon ouverte suppose que la fiche de l'aventure (son indicateur `premium`) ait pu être lue ;
    sinon l'état apparaît à la prochaine action (402) ;
  - **états réseau** : la perte est vue par les événements de la socket Phoenix et `online`/`offline` du navigateur ;
    une connexion coupée en silence n'est remarquée qu'au battement de cœur (30 s) ; les pages servies par un
    contrôleur (connexion, inscription) n'ont que l'état « hors ligne ». « Retry now » utilise la routine interne de
    reconnexion immédiate de la socket (`handleVisibilityChange`, repli `disconnect`/`connect`), à revérifier à chaque
    mise à jour de Phoenix ;
  - **polices** : sous-ensembles latin et latin-ext seulement (un autre alphabet utilise la police du système), style
    normal seulement (l'italique est synthétisé par le navigateur) ;
  - **aide** : recherche par mots exacts (sous-chaînes, accents et casse ignorés), dans la langue de la page, sans
    racinisation ni synonymes ;
  - **page d'accueil** : aucun témoignage ni note n'est affiché ; l'aperçu du studio est une illustration
    statique.
- **Leçons hors ligne (PWA, [contrat](contracts/offline.md))** :
  - **copie sur l'appareil** : une leçon téléchargée est gardée telle quelle par le navigateur (IndexedDB), ni chiffrée
    ni protégée contre la copie : toute personne qui utilise l'appareil (ou lit son stockage) peut la lire et la
    copier. C'est dit sur la page de la leçon, dans l'aide, les paramètres et les pages juridiques ;
  - **appareil qui ne se reconnecte jamais** : il garde ses copies jusqu'à leur expiration (14 jours au plus après le
    téléchargement, jamais après la fin de la période payée) ; l'expiration est contrôlée avec l'horloge de l'appareil,
    qu'un utilisateur peut reculer pour continuer à lire sa copie : le serveur, lui, revérifie l'accès et la révision
    de la leçon à la synchronisation ;
  - **fin d'accès** : la purge immédiate (`ml:offline-purge`) n'atteint que les pages ouvertes à ce moment ; un autre
    appareil purge ses copies à sa prochaine page ouverte en ligne (contrôle des droits chez billing) ; une réponse en
    attente reste en file et sera refusée explicitement si l'accès est toujours terminé ;
  - **périmètre** : seuls les récits et les quiz des aventures premium ; ni les leçons gratuites, ni le code, la vidéo,
    la simulation ou les mini-jeux ; les notes et brouillons ne sont pas disponibles hors ligne ;
  - **une action en attente par leçon** : tant qu'elle attend, le formulaire est désactivé (raison affichée) ; une
    réponse en file ne peut pas être retirée (« Clear offline data » supprime tout, réponses comprises) ;
  - **série** : une réponse hors ligne compte le jour (UTC) de sa synchronisation, pas celui où elle a été donnée : une
    série peut se rompre pendant des jours sans connexion (choix volontaire : aucune date du client n'est crue) ;
  - **synchronisation** : au chargement d'une page en ligne, à l'événement `online` du navigateur et par « Synchronize
    now » ; pas de Background Sync (un onglet du site doit être ouvert) ; 50 actions par requête (le reste au tour
    suivant) ; une connexion coupée en silence n'est vue qu'à l'échec d'une requête ;
  - **reçus d'idempotence** (learning) : gardés jusqu'à la suppression du compte, sans purge (un reçu effacé laisserait
    une action rejouée compter une seconde tentative ; l'XP resterait unique) ;
  - **déconnexion** : `Clear-Site-Data: "storage"` efface aussi le localStorage et le sessionStorage du site et
    désinscrit le service worker (réinstallé à la connexion suivante) ; son effet dépend du navigateur (vérifié dans
    Chrome seulement) : le script de la page efface aussi la base, les caches et le service worker avant d'envoyer la
    déconnexion ; une session qui expire sans déconnexion laisse les copies jusqu'à ce qu'un autre membre se connecte
    sur l'appareil ou qu'elles expirent ;
  - **stockage du navigateur** : il peut évincer IndexedDB et le Cache Storage sous pression d'espace (aucune demande
    de stockage persistant) ; la navigation privée efface tout à la fermeture ; la taille affichée est celle du paquet
    (JSON), pas l'espace réellement occupé ;
  - **abonnement sans fin de période connue** (par exemple un événement Stripe sans `current_period_end`) ou en grâce
    d'impayé : pas de téléchargement (`409 no_paid_period`, expliqué) ;
  - **service worker** : enregistré seulement sur un appareil où un membre a rendu une leçon disponible hors ligne ;
    après « Clear offline data », une page restée ouverte reste contrôlée par l'ancien worker jusqu'à son prochain
    chargement (comportement du navigateur), mais ce worker ne recrée aucun cache supprimé ; en développement, les fichiers non digérés
    sont pris au réseau d'abord (la copie gardée est réécrite à chaque chargement) ; en production, `mix phx.digest` et
    cache d'abord ; mise à jour par `skipWaiting` (une page déjà ouverte avec d'anciens fichiers digérés peut ne plus
    les retrouver hors ligne après la mise à jour) ; la compatibilité avec `mix phx.digest` a été vérifiée en digérant
    une copie de `priv/static` dans un dossier temporaire (noms `app-<empreinte>.js`, icônes et polices digérés, URL des
    polices réécrites dans le CSS avec `?vsn=d`, comme celles du précache), pas sur une release de production réelle ; la page hors ligne gardée reprend la langue et les préférences
    d'affichage de son dernier chargement en ligne (thème VIP non appliqué) ;
  - **navigateurs** : vérifié dans Chrome uniquement (`indexedDB.databases()`, Web Locks, Clear-Site-Data, Cache
    Storage) ; Safari et Firefox non testés ; les retours calculés par learning pour GroveScript et les mini-jeux restent
    en anglais (contenu du service).
- **Stockage des fichiers téléversés** (avatars, pièces jointes, studio) : `ACCOUNTS_STORAGE_DIR`, `SOCIAL_STORAGE_DIR` et
  `STUDIO_STORAGE_DIR` doivent être des chemins absolus ; une valeur vide vaut une variable absente (valeur par défaut en
  dev et en test) ; en production, leur absence empêche le démarrage (il n'y a plus de repli vers un dossier temporaire,
  qui aurait perdu les fichiers au redémarrage). Vérifié par des tests de `config/runtime.exs`, pas sur une release.

## Accessibilité

Objectif : WCAG 2.2 niveau AA. **Aucune conformité n'est revendiquée** : un audit automatisé et des vérifications
scriptées trouvent une partie des obstacles seulement. Tout est vérifié dans Chrome (headless), sur la pile de dev.

- **Vérifié automatiquement** (`e2e/a11y.mjs`, axe-core 4.14.1) : règles WCAG 2.0, 2.1 et 2.2 de niveaux A et AA
  qu'axe sait tester, sur les pages de `responsive.mjs` (visiteur, membre Premium, administratrice), des pages du
  modérateur, toutes les sections des paramètres, des pages de détail, le lecteur de chaque format de leçon, des états
  construits (hors ligne et reconnexion, page `/offline` sans réseau, avis et toasts, dialogue du studio, menu mobile,
  panneaux, formulaires en erreur, réponses des leçons, salon et partie, messagerie, forum, double authentification) et
  les pages d'erreur 403 / 404 / 500 ; thèmes sombre et clair partout, contraste renforcé (sombre et clair) en anglais,
  thèmes VIP sur un échantillon ; anglais et français. **Contraste** : le fond du site est un dégradé, sur lequel axe
  ne tranche pas ; ce texte est mesuré sur le rendu (texte rendu transparent, capture, rapport calculé contre chaque
  pixel du fond sous le texte, seuil d'axe) ; un contrôle de l'outil vérifie à chaque exécution qu'un texte trop pâle
  injecté est bien détecté. Le texte recouvert par un menu ou un dialogue ouvert n'est pas mesuré (il n'est pas visible).
  `bin/test` calcule en plus le contraste des jetons de chaque thème.
- **Vérifié par script** (`e2e/keyboard.mjs`) : sur des pages clés (390 et 1280 px), chaque contrôle atteint par Tab dans
  l'ordre du document, focus visible (style calculé : contour ou ombre portée qui n'existe qu'avec le focus), jamais
  entièrement caché (en-tête collant, barre mobile, toast), aucun piège, lien d'évitement ; parcours au clavier seul
  (connexion, leçon, message, sujet de forum, paramètres, page hors ligne sans réseau), dialogue modal (Échap, focus
  rendu), menu mobile, panneau de signalement ; sur toutes les pages : cibles ≥ 24 px ou assez espacées, espacement du
  texte (1.4.12), zoom de la page à 200 % (640 px CSS, densité 2), aucun élément déplaçable, lien d'aide au même endroit
  relatif (3.2.6) ; mouvement réduit (préférence de l'appareil et du membre) ; collage et saisie automatique dans les
  champs d'authentification, aucun CAPTCHA (3.3.8) ; messages de statut dans une zone live présente avant eux, sans
  déplacer le focus (4.1.3), et focus sur le premier champ en erreur après un envoi refusé. Reflow à 320 px sans
  défilement horizontal : `responsive.mjs`, en anglais et en français.
- **Non vérifié** :
  - aucune technologie d'assistance : lecteurs d'écran (NVDA, JAWS, VoiceOver, TalkBack), commande vocale, loupes ; la
    qualité des annonces (zones live, noms accessibles, ordre de lecture) n'est connue que par le DOM ;
  - autres navigateurs (Firefox, Safari), mobiles réels, mode « couleurs forcées » de Windows ;
  - critères qu'un outil ne juge pas : pertinence des textes alternatifs et des libellés, clarté des contenus et des
    erreurs, cohérence de la navigation, sous-titres et transcription au-delà de leur présence, accessibilité cognitive ;
  - relecture du français par un locuteur natif ;
  - essais avec des personnes en situation de handicap.
- **Limites connues** :
  - contraste des éléments non textuels (bordures des champs, 1.4.11) garanti seulement en mode « contraste élevé » ;
  - texte seul agrandi à 200 % (sans zoom de la page) : quelques pages au contenu large défilent horizontalement : à la
    passe finale, trois leçons (simulation +38 px, leçon premium +11 px, quiz +2 px ; relevé par `keyboard.mjs`, non
    bloquant ; les tableaux du staff, qui défilaient avant le passage de leurs cellules en `overflow-wrap: anywhere`, ne
    défilent plus) : les mises en page suivent la largeur de la fenêtre, pas la taille du texte ; le zoom de la page à
    200 %, qui satisfait 1.4.4, passe sur toutes les pages ;
  - aperçus d'une ligne (dernier message d'une conversation, extrait d'une discussion) tronqués par des points de
    suspension, aussi quand l'espacement du texte est agrandi : le texte entier est sur la page ouverte ;
  - le dialogue de confirmation du studio est une modale native (`<dialog>`, `showModal`) sans voile assombri : la page
    reste visible derrière, inerte ; Échap le ferme et rend le focus au bouton qui l'a ouvert ;
  - en dev, les pages d'erreur thématiques sont remplacées par Plug.Debugger (`debug_errors`) : leur gabarit est audité en
    le faisant rendre par le nœud web en marche (dans chaque langue) ; d'après le code (non observable en dev), la page
    404 d'une URL qu'aucune route ne reconnaît reste en anglais pour un visiteur francophone : aucun pipeline du routeur
    ne s'exécute alors, donc la langue n'est pas fixée (une 404 levée par une page (aventure, leçon, document juridique
    inconnus) suit bien la langue) ; correction possible : un plug de langue au niveau de l'endpoint, sans session ;
  - le mini-jeu « constellation » garde une carte décorative (`aria-hidden`) : les boutons des étoiles en sont
    l'équivalent.

