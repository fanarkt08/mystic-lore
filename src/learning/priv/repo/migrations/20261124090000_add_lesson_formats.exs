defmodule MlLearning.Repo.Migrations.AddLessonFormats do
  use Ecto.Migration

  # Formats vidéo, simulation et mini-jeu.
  def up do
    drop constraint(:lessons, :kind_valid)

    create constraint(:lessons, :kind_valid,
             check: "kind IN ('story','exercise','coding','video','simulation','minigame')"
           )
  end

  def down do
    drop constraint(:lessons, :kind_valid)
    create constraint(:lessons, :kind_valid, check: "kind IN ('story','exercise','coding')")
  end
end
