defmodule MlAccounts.Repo.Migrations.AddPrivacy do
  use Ecto.Migration

  # Uniquement additive : le code précédent fonctionne sur une base migrée.
  def change do
    # Suppression programmée (échéance) puis effectuée (compte anonymisé).
    alter table(:users) do
      add :deletion_scheduled_at, :utc_datetime
      add :deleted_at, :utc_datetime
    end

    create index(:users, [:deletion_scheduled_at],
             where: "deletion_scheduled_at IS NOT NULL AND deleted_at IS NULL",
             name: :users_deletion_due_index
           )

    # Étapes réussies de l'exécuteur (une par service) : une relance saute ce qui est fait.
    create table(:deletion_steps, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :service, :string, primary_key: true
      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Exports de données : assemblés en tâche de fond, conservés 24 h une fois terminés.
    create table(:data_exports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :data, :map
      add :failed_services, {:array, :string}, null: false, default: []
      add :completed_at, :utc_datetime
      add :expires_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:data_exports, [:user_id, :inserted_at])
    create index(:data_exports, [:expires_at])

    create constraint(:data_exports, :data_exports_status,
             check: "status IN ('pending', 'ready', 'failed')"
           )
  end
end
