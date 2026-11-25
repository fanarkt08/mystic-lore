#!/bin/sh
# Migrations, seeds de démo si SEED_DEMO=true, puis démarrage du release (REPO est vide pour web).
set -e
if [ -n "$REPO" ]; then
  /app/bin/"$APP" eval "Application.load(:$APP); {:ok, _, _} = Ecto.Migrator.with_repo($REPO, &Ecto.Migrator.run(&1, :up, all: true))"
  if [ "$SEED_DEMO" = "true" ]; then
    /app/bin/"$APP" eval "Application.ensure_all_started(:ml_shared); Application.load(:$APP); {:ok, _, _} = Ecto.Migrator.with_repo($REPO, fn _ -> Code.eval_file(Application.app_dir(:$APP, \"priv/repo/seeds.exs\")) end)"
  fi
fi
exec /app/bin/"$APP" start
