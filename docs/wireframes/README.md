# Maquettes Figma de MysticLore

Source : le fichier Figma « MysticLore », exporté en PNG le 24/11/2026. Les images ont deux origines.

**Faites à la main, au départ du projet** (fichiers `main-*`) :
- l'accueil, en desktop et en mobile, sur une illustration plein écran ;
- l'en-tête : logo, recherche, liens « Cours, Plans, Activités, Socials », pastille du membre, badges et avatar ;
- le pied de page : la citation « L'esprit n'est pas un vase à remplir, mais un feu à allumer. » et les liens « À
  propos, Contact, FAQ / Aide, Plan du site » et « Mentions légales, Politique de confidentialité, Conditions
  d'utilisation, Gestion des cookies ».

Trois plans de travail vides de l'export n'ont pas été gardés.

**Générées ensuite avec l'IA de Figma**, en prolongeant ces maquettes :
- les 12 écrans du cahier des charges, en desktop (1440 px) et en mobile (390 px) ;
- le design system (`00-design-system.png`).

**L'appli suit les écrans générés avec l'IA de Figma**, y compris pour le logo, l'en-tête, le pied de
page et l'illustration de l'accueil. Elle garde les noms déjà utilisés dans l'appli : Aventures, Abonnement,
Multijoueur, Communauté. Les maquettes faites main (`main-*`) ne servent plus de référence.

Les écarts ci-dessous viennent d'une comparaison avec des captures de l'appli à 1440 px, faites avant l'ajout du mode
hors ligne et de l'audit d'accessibilité. Les versions mobiles n'ont été revues que sur la navigation.

## Correspondance entre maquettes et appli

| Maquette | Page de l'appli |
|---|---|
| 00 Design system | jetons et composants (`src/web/assets/css/app.css`, `components/`) |
| 01 MysticLore landing | `/` |
| 02 Adventure discovery | `/adventures` |
| 03 Learner dashboard | `/dashboard` |
| 04 Interactive course player | `/learn/:slug/:lesson_id` |
| 05 Multiplayer activities | `/multiplayer`, `/multiplayer/lobbies/:id` |
| 06 AI creation studio | `/studio/:id` (éditeur de projet), `/studio` |
| 07 Customizable learner profile | `/members/:username`, `/settings` (profil), `/achievements` |
| 08 Friends and messaging | `/friends`, `/messages`, `/messages/:id` |
| 09 Community forum | `/community`, `/community/discussions/:slug` |
| 10 Subscription plans | `/membership` |
| 11 Complete account settings | `/settings/:section` |
| 12 Admin operations dashboard | `/admin` et ses pages |

## Déjà conforme
- **Style** : palette sombre « minuit » et violet d'action, titres en Cormorant Garamond et texte en Inter, cartes à
  bordure fine, pastilles de format et d'accès, barres de progression.
- **Navigation** : rail latéral pour les membres, barre de navigation en bas sur mobile.
- **Fonctions** : abonnements Free / Premium / VIP et crédits IA, quêtes du jour, XP et badges, salon du Rune Relay
  avec lien d'invitation et validation par l'hôte, éditeur du studio avec crédits, relecture et publication,
  signalements et sanctions.

## Écarts communs à tous les écrans
1. **En-tête** : la maquette ajoute une barre en haut de chaque page.
   - Le nom « ✧ MysticLore ✧ » centré.
   - Une **recherche globale**.
   - Les liens Adventures, Membership, Multiplayer, Community.
   - Une pastille « Nom · Lv. N » avec trois badges et l'avatar.
   - Aujourd'hui, les membres n'ont que le rail.
2. **Rail « My realm »** :
   - entrées de la maquette : Adventures, Dashboard, Multiplayer, Creation studio, Friends & messages (fusionnés),
     My profile, Membership, Settings ;
   - en bas du rail : une carte du membre (avatar, badges, « Level 12 · Moonweaver », formule).
   - L'appli sépare Friends et Messages, a Achievements, et n'a pas d'entrée « My profile ».
3. **Mobile** :
   - une barre de section (nom de la page et menu) ;
   - une navigation à 5 destinations (Explore, Home, Play, Social, You), à faire correspondre à la barre du bas
     actuelle.
4. **Pied de page** :
   - accueil : une citation centrée et deux colonnes de liens. À gauche Our story, Contact, Help center, Academy map ;
     à droite Legal, Privacy, Terms, Cookies ;
   - pages membres : une ligne « MysticLore · Stay curious. / Help · Privacy ».
   - Il manque une page « Our story » (provisoire), un plan du site HTML et le lien Cookies, ce dernier étant
     prévu.
5. **Illustrations** : la maquette met une illustration partout.
   - Le château de l'accueil, la couverture de chaque aventure, l'image de chaque leçon.
   - La couverture du profil, le salon multijoueur, l'aperçu du studio.
   - L'appli reprend les illustrations des maquettes pour le château de
     l'accueil et les couvertures des 4 aventures (WebP dans `src/web/priv/static/images/art/`), reprises aussi par
     la couverture du profil. Les leçons, le salon et le studio n'ont pas d'image ; une couverture sans image garde
     un dégradé, sans libellé « provisoire ».
6. **Jetons du design system** : appliquer les valeurs exactes.
   - Couleurs : Canvas `#090E20`, Surface `#111A32`, Raised `#192440`, Border `#2C3858`, Action `#7954E8`, Magic
     `#AD8BFF`, Information `#74E6E2`, Reward `#EDCA85`, Success `#8FE0B5`, Danger `#FFABAC`, Text `#F3F1FF`, Muted
     `#ADB7D1`.
   - Tailles de texte : affichage 88 → 56, titre de page 48 → 38, texte courant 15–16 px.
   - Rayons 8 / 16 / 24 et espacements 4 à 64.
   - Contrôles de 46 px de haut au moins, anneau de focus cyan de 2 px.
7. **Thèmes VIP** : la maquette a Moonlit Academy (violet), Twilight Grove (sarcelle) et Astral Gold (or). L'appli a
   `grove`, `ember` et `parchment`, à renommer et recolorer.

## Écarts par écran
- **01 Accueil** :
  - héros illustré, deux boutons, et des cartes d'aventure illustrées ;
  - sections « You change the story » (formats), « From a spark to a superpower » (3 étapes) et « Find your party »
    (aperçu du Rune Relay) ;
  - sections « Turn what if into a world » (studio) et « Little wins » (profil et badges) ;
  - tarifs, FAQ en cartes, appel final et pied de page à citation.
- **02 Catalogue** :
  - recherche « Search the atlas » et puces de catégorie (dont « Saved ») ;
  - panneau de filtres à cases à cocher avec effectifs : difficulté, format de leçon, accès, durée ;
  - grande carte « Chosen for your curiosity », cartes illustrées avec formats et durée, pagination.
- **03 Tableau de bord** :
  - salutation avec la date, carte « Continue your adventure » illustrée ;
  - « Your party is gathering » (invitation de salon) ;
  - tuiles Niveau / Série / Succès et « A new badge is within reach » ;
  - graphique de la semaine, recommandations illustrées et « From your guild » (activité des amis).
- **04 Lecteur** :
  - panneau « Adventure journal » : progression, leçons avec format et durée, récompense ;
  - onglets Story / Code lab / Transcript / Notes / Captions ;
  - encadré « Your mission », défi de code, simulation, bilan, puis « Add it to your spellbook ».
  - La maquette réunit récit, code et simulation dans une même leçon.
- **05 Multijoueur** :
  - « The Guild Hall » avec trois onglets : My party, Open lobbies, Scheduled ;
  - carte du salon illustrée, joueurs « Ready », chat et panneau d'invitation ;
  - « How the relay works », plus deux autres activités : jardin collaboratif et duel.
- **06 Studio** :
  - éditeur en 5 étapes (Brief → Outline → Build → Review → Publish), constructeur de modules par format ;
  - éditeur de chapitre et liste de vérification avant publication ;
  - colonne de droite : crédits, aperçu élève, illustration IA (VIP) et réglages (co-auteurs, mention IA,
    versions).
- **07 Profil** :
  - une seule page « Adventurer's card » : couverture, statistiques et badges à équiper ;
  - aventures et créations, jalons récents ;
  - modification sur place et réglages de confidentialité.
- **08 Amis et messages** :
  - une seule page « The Common Room » : conversations, demandes d'ami, fil avec en-tête (en ligne, sourdine,
    blocage, signalement) ;
  - carte d'invitation de salon dans le fil, et « Friends around the academy ».
- **09 Forum** :
  - onglets For you / Recent / Unanswered / Following, recherche, « Start a discussion » ;
  - à droite : « Find your circle » (cercles et effectifs), « Around the campfire » (présents, événements) et
    « Keep the magic kind » (règles, signalement).
- **10 Abonnement** :
  - héros, cartes de formules avec leurs crédits et la note « Concept membership pricing » ;
  - « The details, without the fine print », « Your membership », « What stays free? » et FAQ.
- **11 Paramètres** : une seule page, toutes les sections ouvertes sur deux colonnes.
  - The essentials, Your adventurer identity, Choose your kind of magic ;
  - Set your boundaries, A safer common room.
- **12 Admin** :
  - « Warden console » avec son propre rail et des tuiles d'indicateurs ;
  - file de signalements, santé des services, opérations de crédits, revue des cours, dossier sélectionné.

## Écarts volontaires, à expliquer dans le mémoire
Le cahier des charges interdit tout chiffre inventé (« Aucun indicateur opérationnel fictif en production ») et tout
avis présenté comme réel. Dans l'appli, chacun de ces éléments est remplacé par une valeur réelle, retiré ou marqué
« indisponible » :
- « 1,284 explorers online » et « 218 explorers here now » ;
- les notes « ★ 4.9 » et « 12,000+ adventures begun » ;
- « 99.98 % uptime » et « p95 latency 182 ms » ;
- les témoignages de « Samira » et « Theo ».

## Montré dans les maquettes, absent de l'appli
**À créer** :
- la recherche globale de l'en-tête ;
- les aventures sauvegardées ;
- les notes des aventures : seulement après avoir terminé l'aventure, avec la moyenne réelle ;
- le fil d'activité des amis, seulement pour les amis qui l'acceptent.

**Évolutions futures**, à présenter comme telles dans le mémoire :
- les leçons qui mêlent plusieurs formats, et la durée de chaque leçon ;
- les « minutes apprises » (l'appli compte l'XP) ;
- les autres activités multijoueur ;
- les événements communautaires ;
- les cercles du forum avec leurs effectifs.

Les illustrations des maquettes ont été générées par l'IA de Figma pour ce projet. Elles peuvent être reprises
dans l'appli.
