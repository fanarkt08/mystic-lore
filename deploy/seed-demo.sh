#!/bin/sh
# Crée les données de démo, une seule fois après le premier démarrage (mot de passe : SEED_DEMO_PASSWORD du .env).
set -eu
cd /opt/mysticlore
C="docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml"
for s in accounts learning billing social multiplayer community studio notifications; do
  echo "=== $s"
  $C exec -T "$s" sh -c '/app/bin/$APP eval "Application.ensure_all_started(:ml_shared); Application.load(:$APP); {:ok, _, _} = Ecto.Migrator.with_repo($REPO, fn _ -> Code.eval_file(Application.app_dir(:$APP, \"priv/repo/seeds.exs\")) end)"'
done
