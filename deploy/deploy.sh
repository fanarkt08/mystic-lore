#!/bin/sh
# Déploie un commit sur le serveur : code, images reconstruites une par une, redémarrage, vérification HTTPS.
# Lancé par la CI via SSH (clé limitée à ce script) ; le commit arrive dans SSH_ORIGINAL_COMMAND.
set -eu
cd /opt/mysticlore
SHA="${SSH_ORIGINAL_COMMAND:-${1:-}}"
case "$SHA" in
  "" | *[!0-9a-f]*) echo "commit attendu (hexadécimal)" >&2; exit 2 ;;
esac
git fetch -q origin main
git reset -q --hard "$SHA"
C="docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml"
# Une image à la fois : deux compilations Elixir en parallèle dépassent la mémoire du serveur.
for s in accounts learning billing social multiplayer community studio notifications web; do
  $C build -q "$s"
done
$C up -d --remove-orphans
HOST=$(grep '^PHX_HOST=' .env | cut -d= -f2)
for _ in $(seq 1 36); do
  if curl -sf "https://$HOST/healthz" > /dev/null; then
    docker image prune -f > /dev/null
    echo "déployé : $(git log --format='%h %s' -1)"
    exit 0
  fi
  sleep 5
done
echo "le site ne répond pas après le déploiement" >&2
exit 1
