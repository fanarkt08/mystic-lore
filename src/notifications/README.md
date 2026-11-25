# MlNotifications : centre de notifications de MysticLore (port 4008)

Notifications des membres, créées par les autres services (chacun ses catégories), lues par `web` : liste par
curseur, compteur de non-lues, lecture, préférences par catégorie × canal (in-app, e-mail ; lignes verrouillées),
heures calmes dans le fuseau IANA du membre (changements d'heure compris), e-mails demandés à accounts (aucune
adresse stockée ici), report pendant les heures calmes et résumé unique à leur fin, limite de débit, rétention.
API JSON interne (jeton `MlShared.Plug.Internal`, jamais appelée par le navigateur) : voir
[docs/contracts/notifications.md](../../docs/contracts/notifications.md). Base `ml_notifications_dev` /
`ml_notifications_test`.

    mix setup          # dépendances, base, migrations, seeds de démo (idempotents)
    mix phx.server     # http://localhost:4008/healthz
    mix test

Jamais de texte rédigé, d'URL ni de contenu privé en base : `kind` + `params` (identifiants, courtes chaînes
publiques). `web` traduit et calcule le lien.

Variables : `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `PORT` (4008), `ACCOUNTS_URL` (http://localhost:4001, envoi des
e-mails et identités des acteurs), `CLUSTER_NODES` (PubSub partagé : `{:notifications_changed, id, toast}`),
`NOTIFICATIONS_EMAIL_DELAY_S` (délai d'un e-mail facultatif, 60 s par défaut, 10 s en dev) ; en prod
`INTERNAL_SECRET`, `DATABASE_URL`, `SECRET_KEY_BASE`.

Tâches Oban : `email` (e-mails unitaires et résumés), `maintenance` (purge quotidienne à 03:17 UTC : 90 jours,
500 par membre).
