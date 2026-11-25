defmodule MlLearning.Repo.Migrations.AddImportFields do
  use Ecto.Migration

  # Aventures importées depuis le studio : origine, identifiant externe, version.
  def change do
    alter table(:adventures) do
      add :source, :string
      add :external_id, :binary_id
      add :imported_version, :integer
      add :author_id, :binary_id
    end

    create unique_index(:adventures, [:source, :external_id],
             where: "external_id IS NOT NULL",
             name: :adventures_source_external_id_index
           )

    create constraint(:adventures, :import_fields_consistent,
             check:
               "(source IS NULL) = (external_id IS NULL) AND (external_id IS NULL) = (imported_version IS NULL)"
           )
  end
end
