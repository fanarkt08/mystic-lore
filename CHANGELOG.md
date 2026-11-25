# Changelog

- Passage du monolithe Phoenix à des services séparés : web, accounts, learning, billing et social, plus la bibliothèque `src/shared`.
- Paiement Stripe en mode test, ou simulé en local, avec webhooks signés.
- Ajout du multijoueur, du forum et du studio de création assisté par IA, avec ses crédits.
- Badges, quêtes quotidiennes et sécurité des comptes (2FA, sessions actives, mot de passe oublié).
- Administration et modération, journal d'audit, export et suppression des données personnelles.
- Formats de leçon vidéo, simulation et mini-jeu, avec un moteur de simulation natif facultatif en Rust.
- Paramètres complets et profil enrichi.
- Messagerie de groupe avec pièces jointes, puis centre de notifications.
- Aide, contact, pages juridiques provisoires et accueil guidé.
- Lecture hors ligne des leçons premium (PWA).
- Audit d'accessibilité, passe de traduction française et contenus de démo en français.
- Dockerfile, docker-compose et configuration de production avec Caddy.
