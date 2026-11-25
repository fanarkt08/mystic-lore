defmodule MlLearning.Repo.Migrations.CreateLearning do
  use Ecto.Migration

  def change do
    create table(:adventures, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :title, :string, null: false
      add :summary, :text, null: false
      add :description, :text, null: false, default: ""
      add :category, :string, null: false
      add :difficulty, :string, null: false
      add :premium, :boolean, null: false, default: false
      add :duration_minutes, :integer, null: false
      add :cover, :string, null: false
      add :objectives, {:array, :text}, null: false, default: []
      add :prerequisites, {:array, :text}, null: false, default: []
      timestamps(type: :utc_datetime)
    end

    create unique_index(:adventures, [:slug])

    create constraint(:adventures, :category_valid,
             check: "category IN ('coding','science','humanities','creative')"
           )

    create constraint(:adventures, :difficulty_valid,
             check: "difficulty IN ('beginner','intermediate','advanced')"
           )

    create constraint(:adventures, :cover_valid,
             check: "cover IN ('forest','observatory','alchemy','archive')"
           )

    create constraint(:adventures, :duration_positive, check: "duration_minutes > 0")

    create table(:chapters, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :adventure_id, references(:adventures, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :title, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:chapters, [:adventure_id, :position])

    create table(:lessons, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :chapter_id, references(:chapters, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :title, :string, null: false
      add :kind, :string, null: false
      add :body, :text, null: false, default: ""

      # `content` est exposé au client ; `solution` (réponse attendue, explications) ne l'est jamais.
      add :content, :map, null: false, default: %{}
      add :solution, :map, null: false, default: %{}
      add :xp_reward, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:lessons, [:chapter_id, :position])
    create constraint(:lessons, :kind_valid, check: "kind IN ('story','exercise','coding')")
    create constraint(:lessons, :xp_reward_positive, check: "xp_reward > 0")

    # user_id : identifiant du service accounts (pas de clé étrangère inter-bases).
    create table(:enrollments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false

      add :adventure_id, references(:adventures, type: :binary_id, on_delete: :delete_all),
        null: false

      add :last_lesson_id, references(:lessons, type: :binary_id, on_delete: :nilify_all)
      add :completed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:enrollments, [:user_id, :adventure_id])
    create index(:enrollments, [:user_id, :updated_at])

    create table(:lesson_progress, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :lesson_id, references(:lessons, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "in_progress"
      add :attempts, :integer, null: false, default: 0
      add :notes, :text
      add :draft, :text
      add :completed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:lesson_progress, [:user_id, :lesson_id])
    create index(:lesson_progress, [:lesson_id])

    create constraint(:lesson_progress, :status_valid,
             check: "status IN ('in_progress','completed')"
           )

    create constraint(:lesson_progress, :attempts_nonneg, check: "attempts >= 0")

    # Idempotence de l'XP : une récompense (`lesson:<id>`, `adventure:<id>`) au plus une fois par utilisateur.
    create table(:xp_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :ref_key, :string, null: false
      add :amount, :integer, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:xp_events, [:user_id, :ref_key])
    create index(:xp_events, [:user_id, :inserted_at])
    create constraint(:xp_events, :amount_positive, check: "amount > 0")
  end
end
