defmodule MlSocial.Repo.Migrations.AddModeration do
  use Ecto.Migration

  # Modération des signalements. Uniquement additive.
  def change do
    # Retrait par la modération : suppression logique (le texte reste pour les preuves et les appels, il n'est
    # plus jamais renvoyé dans une conversation).
    alter table(:messages) do
      add :removed_at, :utc_datetime_usec
      add :removed_by, :binary_id
    end

    alter table(:reports) do
      add :status, :string, null: false, default: "open"
      add :resolution, :string
      add :resolution_reason, :text
      add :resolved_by, :binary_id
      add :resolved_at, :utc_datetime_usec
      # sanction posée chez accounts (avertissement, restriction)
      add :sanction_id, :binary_id
    end

    create constraint(:reports, :reports_status, check: "status IN ('open', 'resolved')")

    create constraint(:reports, :reports_resolution,
             check:
               "resolution IS NULL OR resolution IN ('dismiss', 'remove_message', 'warn', 'restrict')"
           )

    create index(:reports, [:status, :inserted_at])
  end
end
