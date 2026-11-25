defmodule MlLearning.Repo.Migrations.CreateGamification do
  use Ecto.Migration

  # Liste blanche des icônes de badges (heroicons « outline ») ; la même liste est écrite en toutes lettres
  # côté web (MysticWeb.GamificationComponents) pour que Tailwind génère les classes `hero-*`.
  @icons ~w(hero-sparkles hero-sun hero-flag hero-star hero-bolt hero-academic-cap hero-trophy hero-fire
            hero-moon hero-users hero-book-open hero-shield-check hero-light-bulb hero-puzzle-piece hero-map
            hero-beaker hero-rocket-launch hero-pencil-square)

  def change do
    create table(:badges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :text, null: false
      add :icon, :string, null: false
      add :rarity, :string, null: false
      add :criterion, :string, null: false
      # `lesson_completed` : titre de la leçon visée
      add :param, :string
      add :target, :integer, null: false
      add :position, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:badges, [:slug])
    create constraint(:badges, :icon_allowed, check: "icon IN (#{sql_list(@icons)})")

    create constraint(:badges, :rarity_valid,
             check: "rarity IN ('common','uncommon','rare','epic','legendary')"
           )

    create constraint(:badges, :criterion_valid,
             check:
               "criterion IN ('lessons_completed','lesson_completed','adventures_completed','total_xp','level','streak_days','multiplayer_wins')"
           )

    create constraint(:badges, :target_positive, check: "target > 0")

    # user_id : identifiant du service accounts (pas de clé étrangère inter-bases).
    create table(:user_badges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :badge_id, references(:badges, type: :binary_id, on_delete: :delete_all), null: false
      add :earned_at, :utc_datetime, null: false
      add :equipped, :boolean, null: false, default: false
      add :position, :integer
    end

    # Attribution idempotente ; au plus 3 badges équipés : position 1..3, unique par utilisateur.
    create unique_index(:user_badges, [:user_id, :badge_id])
    create unique_index(:user_badges, [:user_id, :position])
    create index(:user_badges, [:badge_id])

    # `position IS NOT NULL` explicite : un CHECK évalué à NULL serait accepté.
    create constraint(:user_badges, :equipped_position,
             check:
               "(equipped AND position IS NOT NULL AND position BETWEEN 1 AND 3) OR (NOT equipped AND position IS NULL)"
           )

    # Quêtes quotidiennes : la progression du jour est calculée, la récompense est un xp_event `quest:<id>:<date>`.
    create table(:quests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :title, :string, null: false
      add :description, :text, null: false
      add :kind, :string, null: false
      add :target, :integer, null: false
      add :xp_reward, :integer, null: false
      add :position, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:quests, [:slug])

    create constraint(:quests, :kind_valid,
             check: "kind IN ('lessons_completed','xp_earned','note_written')"
           )

    create constraint(:quests, :target_positive, check: "target > 0")
    create constraint(:quests, :xp_reward_range, check: "xp_reward BETWEEN 1 AND 500")

    # Date d'enregistrement de la note (quête « écrire une note ») : `updated_at` bouge à chaque tentative.
    alter table(:lesson_progress) do
      add :notes_saved_at, :utc_datetime
    end
  end

  defp sql_list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
