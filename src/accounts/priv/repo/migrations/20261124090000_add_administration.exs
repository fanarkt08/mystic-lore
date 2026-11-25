defmodule MlAccounts.Repo.Migrations.AddAdministration do
  use Ecto.Migration

  # Administration et modération. Uniquement additive.
  def change do
    # Fin de la restriction active la plus lointaine (recalculée à chaque sanction posée ou levée, sous verrou du membre).
    alter table(:users) do
      add :restricted_until, :utc_datetime
    end

    # Journal d'audit central : une ligne par action du staff, écrite par accounts ou par un autre service.
    create table(:audit_entries) do
      add :service, :string, null: false
      add :actor_id, :binary_id, null: false
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :string
      add :reason, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_entries, [:inserted_at])
    create index(:audit_entries, [:actor_id, :inserted_at])
    create index(:audit_entries, [:action, :inserted_at])

    # Ajout seul : un déclencheur refuse toute modification ou suppression d'une entrée.
    execute(
      """
      CREATE FUNCTION audit_entries_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'audit_entries rows are append-only';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION audit_entries_append_only()"
    )

    execute(
      """
      CREATE TRIGGER audit_entries_no_change BEFORE UPDATE OR DELETE ON audit_entries
      FOR EACH ROW EXECUTE FUNCTION audit_entries_append_only()
      """,
      "DROP TRIGGER audit_entries_no_change ON audit_entries"
    )

    # Sanctions : avertissement (sans fin) ou restriction temporaire (fin obligatoire) ; levée = lifted_*.
    create table(:sanctions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :reason, :text, null: false
      add :issued_by, :binary_id, null: false
      add :ends_at, :utc_datetime
      # clé d'idempotence d'un service appelant (ex. "social:report:<id>")
      add :ref, :string
      add :lifted_at, :utc_datetime
      add :lifted_by, :binary_id
      add :lift_reason, :text
      timestamps(type: :utc_datetime)
    end

    create index(:sanctions, [:user_id, :inserted_at])
    create unique_index(:sanctions, [:ref], where: "ref IS NOT NULL")

    create constraint(:sanctions, :sanctions_kind,
             check:
               "(kind = 'warning' AND ends_at IS NULL) OR (kind = 'restriction' AND ends_at IS NOT NULL)"
           )

    # Appel d'un membre : un seul ouvert par sanction (index unique partiel).
    create table(:sanction_appeals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sanction_id, references(:sanctions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "open"
      add :decided_by, :binary_id
      add :decision_reason, :text
      add :decided_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:sanction_appeals, [:status, :inserted_at])
    create index(:sanction_appeals, [:user_id])

    create unique_index(:sanction_appeals, [:sanction_id],
             where: "status = 'open'",
             name: :sanction_appeals_one_open_index
           )

    create constraint(:sanction_appeals, :sanction_appeals_status,
             check: "status IN ('open', 'accepted', 'rejected')"
           )

    # Incidents : résumé obligatoire une fois résolus ; chronologie dans incident_updates.
    create table(:incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :severity, :string, null: false
      add :status, :string, null: false, default: "open"
      add :summary, :text
      add :created_by, :binary_id, null: false
      add :resolved_by, :binary_id
      add :resolved_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:incidents, [:status, :inserted_at])

    create constraint(:incidents, :incidents_severity,
             check: "severity IN ('low', 'medium', 'high', 'critical')"
           )

    create constraint(:incidents, :incidents_status,
             check: "status IN ('open', 'investigating', 'resolved')"
           )

    create constraint(:incidents, :incidents_resolution,
             check:
               "status <> 'resolved' OR (summary IS NOT NULL AND resolved_at IS NOT NULL AND resolved_by IS NOT NULL)"
           )

    create table(:incident_updates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :incident_id, references(:incidents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :author_id, :binary_id, null: false
      add :body, :text, null: false
      # statut posé par cette mise à jour (nil : inchangé)
      add :status, :string
      add :severity, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:incident_updates, [:incident_id, :inserted_at])
  end
end
