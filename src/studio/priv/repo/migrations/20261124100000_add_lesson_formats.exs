defmodule MlStudio.Repo.Migrations.AddLessonFormats do
  use Ecto.Migration

  # Formats vidéo, simulation et mini-jeu ; médias des leçons vidéo (fichiers privés, servis après autorisation).
  def up do
    drop constraint(:lessons, :lessons_kind)

    create constraint(:lessons, :lessons_kind,
             check: "kind IN ('story','exercise','coding','video','simulation','minigame')"
           )

    create table(:media, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :uploader_id, :binary_id, null: false
      add :kind, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      # pistes de sous-titres : langue (BCP 47 court) et libellé
      add :lang, :string
      add :label, :string
      timestamps(type: :utc_datetime)
    end

    create index(:media, [:project_id])

    create constraint(:media, :media_kind_type,
             check:
               "(kind = 'video' AND content_type IN ('video/webm','video/mp4')) OR (kind = 'captions' AND content_type = 'text/vtt' AND lang IS NOT NULL AND label IS NOT NULL)"
           )

    create constraint(:media, :media_size, check: "byte_size > 0 AND byte_size <= 52428800")
  end

  def down do
    drop table(:media)
    drop constraint(:lessons, :lessons_kind)
    create constraint(:lessons, :lessons_kind, check: "kind IN ('story','exercise','coding')")
  end
end
