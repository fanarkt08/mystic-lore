defmodule MlLearning.Repo.Migrations.AddOfflineLessons do
  use Ecto.Migration

  # Leçons hors ligne : révision tenue par un déclencheur et reçus des actions rejouées.
  def up do
    alter table(:lessons) do
      add :revision, :integer, null: false, default: 1
      add :revised_at, :utc_datetime
    end

    execute "UPDATE lessons SET revised_at = updated_at"
    execute "ALTER TABLE lessons ALTER COLUMN revised_at SET DEFAULT now()"
    execute "ALTER TABLE lessons ALTER COLUMN revised_at SET NOT NULL"
    create constraint(:lessons, :revision_positive, check: "revision > 0")

    execute """
    CREATE FUNCTION lessons_track_revision() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        NEW.revision := 1;
        NEW.revised_at := now();
      ELSIF (NEW.title, NEW.kind, NEW.body, NEW.content, NEW.solution)
            IS DISTINCT FROM (OLD.title, OLD.kind, OLD.body, OLD.content, OLD.solution) THEN
        NEW.revision := OLD.revision + 1;
        NEW.revised_at := now();
      ELSE
        NEW.revision := OLD.revision;
        NEW.revised_at := OLD.revised_at;
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER lessons_track_revision BEFORE INSERT OR UPDATE ON lessons
    FOR EACH ROW EXECUTE FUNCTION lessons_track_revision()
    """

    create table(:idempotent_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :key, :binary_id, null: false
      add :lesson_id, references(:lessons, type: :binary_id, on_delete: :delete_all), null: false
      add :action, :string, null: false

      # SHA-256 de (action, leçon, réponse) : une clé réutilisée pour une autre demande est refusée
      add :request_hash, :string, null: false
      add :response, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:idempotent_actions, [:user_id, :key])
    create index(:idempotent_actions, [:lesson_id])

    create constraint(:idempotent_actions, :action_valid,
             check: "action IN ('submit','complete')"
           )
  end

  def down do
    drop table(:idempotent_actions)
    execute "DROP TRIGGER lessons_track_revision ON lessons"
    execute "DROP FUNCTION lessons_track_revision()"
    drop constraint(:lessons, :revision_positive)

    alter table(:lessons) do
      remove :revised_at
      remove :revision
    end
  end
end
