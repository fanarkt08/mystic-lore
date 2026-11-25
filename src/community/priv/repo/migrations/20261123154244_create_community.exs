defmodule MlCommunity.Repo.Migrations.CreateCommunity do
  use Ecto.Migration

  # Les membres vivent dans la base d'accounts : leurs UUID sont stockés ici sans clé étrangère.
  def change do
    create table(:categories, primary_key: false) do
      add :slug, :string, primary_key: true
      add :name, :string, null: false
      add :description, :string, null: false
      add :position, :integer, null: false
      add :staff_only, :boolean, null: false, default: false
    end

    # Données de référence nécessaires dans tous les environnements (tests et production compris).
    execute(
      """
      INSERT INTO categories (slug, name, description, position, staff_only) VALUES
        ('announcements', 'Announcements', 'Official news from the academy team.', 1, true),
        ('help-questions', 'Help & Questions', 'Stuck on a lesson? Ask the circle.', 2, false),
        ('showcase', 'Showcase', 'Share what you built, charted or brewed.', 3, false),
        ('study-groups', 'Study Groups', 'Find companions for your next adventure.', 4, false),
        ('off-topic', 'Off-topic', 'Everything else, kindly.', 5, false)
      """,
      "DELETE FROM categories"
    )

    create table(:discussions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :category, references(:categories, column: :slug, type: :string), null: false
      add :author_id, :binary_id, null: false
      add :title, :string, size: 140, null: false
      add :slug, :string, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "visible"
      add :pinned, :boolean, null: false, default: false
      add :locked, :boolean, null: false, default: false
      add :solution_reply_id, :binary_id
      add :helpful_count, :integer, null: false, default: 0
      add :moderation_reason, :text
      add :edited_at, :utc_datetime_usec
      add :last_activity_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:discussions, [:slug])
    create index(:discussions, [:category])
    create index(:discussions, [:last_activity_at])
    # limite de débit (publications récentes d'un membre)
    create index(:discussions, [:author_id, :inserted_at])

    create constraint(:discussions, :discussions_status,
             check: "status IN ('visible', 'hidden', 'removed', 'deleted')"
           )

    create constraint(:discussions, :discussions_helpful_count, check: "helpful_count >= 0")

    create table(:replies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :discussion_id, references(:discussions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :author_id, :binary_id, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "visible"
      add :helpful_count, :integer, null: false, default: 0
      add :moderation_reason, :text
      add :edited_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:replies, [:discussion_id, :inserted_at])
    create index(:replies, [:author_id, :inserted_at])

    create constraint(:replies, :replies_status,
             check: "status IN ('visible', 'hidden', 'removed', 'deleted')"
           )

    create constraint(:replies, :replies_helpful_count, check: "helpful_count >= 0")

    alter table(:discussions) do
      modify :solution_reply_id, references(:replies, type: :binary_id, on_delete: :nilify_all),
        from: :binary_id
    end

    # Un vote « utile » par (membre, cible) : la clé primaire est la contrainte d'unicité.
    create table(:votes, primary_key: false) do
      add :user_id, :binary_id, primary_key: true
      add :target_type, :string, primary_key: true
      add :target_id, :binary_id, primary_key: true
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:votes, :votes_target_type, check: "target_type IN ('discussion', 'reply')")

    create table(:follows, primary_key: false) do
      add :user_id, :binary_id, primary_key: true

      add :discussion_id, references(:discussions, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:follows, [:discussion_id])

    # Pas de clé étrangère vers la cible : l'instantané (snapshot) se suffit à lui-même.
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reporter_id, :binary_id, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :reason, :string, null: false
      add :details, :text
      add :snapshot, :map, null: false
      add :status, :string, null: false, default: "open"
      add :resolution, :string
      add :resolution_reason, :text
      add :resolved_by, :binary_id
      add :resolved_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:reports, :reports_target_type,
             check: "target_type IN ('discussion', 'reply')"
           )

    create constraint(:reports, :reports_reason,
             check: "reason IN ('harassment', 'spam', 'inappropriate', 'other')"
           )

    create constraint(:reports, :reports_status, check: "status IN ('open', 'resolved')")

    # Un seul signalement ouvert par (rapporteur, cible).
    create unique_index(:reports, [:reporter_id, :target_type, :target_id],
             where: "status = 'open'",
             name: :reports_one_open_index
           )

    create index(:reports, [:status, :inserted_at])
    create index(:reports, [:target_type, :target_id])

    create table(:moderation_log, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :moderator_id, :binary_id, null: false
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :reason, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:moderation_log, [:target_type, :target_id])
    create index(:moderation_log, [:inserted_at])
  end
end
