defmodule MlStudio.Repo.Migrations.CreateStudio do
  use Ecto.Migration

  def change do
    # Users live in the accounts database: no foreign key on user ids.
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, :binary_id, null: false
      add :title, :string, null: false
      add :summary, :text, null: false, default: ""
      add :description, :text, null: false, default: ""
      add :objectives, {:array, :text}, null: false, default: []
      add :prerequisites, {:array, :text}, null: false, default: []
      add :audience, :text, null: false, default: ""
      add :level, :string, null: false, default: "beginner"
      add :duration_minutes, :integer, null: false, default: 30
      add :category, :string, null: false, default: "creative"
      add :cover, :string, null: false, default: "forest"
      add :status, :string, null: false, default: "draft"
      # optimistic lock of the brief; content_revision changes with any content change
      add :lock_version, :integer, null: false, default: 1
      add :content_revision, :integer, null: false, default: 1
      # author's declarations, valid only for the revision they were made on
      add :attestations, :map
      add :attested_revision, :integer
      add :attested_at, :utc_datetime
      add :review_version, :integer
      add :submitted_at, :utc_datetime
      add :reviewed_by, :binary_id
      add :reviewed_at, :utc_datetime
      add :review_reason, :text
      add :import_message, :text
      add :published_slug, :string
      add :published_adventure_id, :string
      add :published_version, :integer
      add :published_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:owner_id])
    create index(:projects, [:status, :submitted_at])

    create constraint(:projects, :projects_status,
             check: "status IN ('draft','submitted','approved','published')"
           )

    create constraint(:projects, :projects_level,
             check: "level IN ('beginner','intermediate','advanced')"
           )

    create constraint(:projects, :projects_category,
             check: "category IN ('coding','science','humanities','creative')"
           )

    create constraint(:projects, :projects_cover,
             check: "cover IN ('forest','observatory','alchemy','archive')"
           )

    create table(:modules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :title, :string, null: false
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create table(:lessons, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :module_id, references(:modules, type: :binary_id, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :title, :string, null: false
      add :kind, :string, null: false
      add :body, :text, null: false, default: ""
      add :xp_reward, :integer, null: false, default: 10
      add :content, :map, null: false, default: %{}
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create index(:lessons, [:project_id])
    create constraint(:lessons, :lessons_kind, check: "kind IN ('story','exercise','coding')")

    # Positions are unique, checked at commit time so that a reordering can swap them.
    for {table, scope} <- [modules: "project_id", lessons: "module_id"] do
      execute(
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_position_unique UNIQUE (#{scope}, position) DEFERRABLE INITIALLY DEFERRED",
        "ALTER TABLE #{table} DROP CONSTRAINT #{table}_position_unique"
      )
    end

    create table(:collaborators, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, :binary_id, null: false
      add :username, :string, null: false
      add :role, :string, null: false
      add :invited_by, :binary_id, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:collaborators, [:project_id, :user_id])
    create index(:collaborators, [:user_id])
    create constraint(:collaborators, :collaborators_role, check: "role IN ('editor','viewer')")

    # Immutable snapshots (a trigger refuses updates); restoring creates a new version.
    create table(:versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      add :note, :string, null: false, default: ""
      add :source, :string, null: false
      add :author_id, :binary_id, null: false
      add :snapshot, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:versions, [:project_id, :number])

    create constraint(:versions, :versions_source,
             check: "source IN ('manual','submission','restore')"
           )

    execute(
      """
      CREATE FUNCTION studio_versions_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'versions are immutable';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION studio_versions_immutable()"
    )

    execute(
      "CREATE TRIGGER versions_no_update BEFORE UPDATE ON versions FOR EACH ROW EXECUTE FUNCTION studio_versions_immutable()",
      "DROP TRIGGER versions_no_update ON versions"
    )

    # Image files live in the private storage directory, named by id.
    create table(:images, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :lesson_id, references(:lessons, type: :binary_id, on_delete: :nilify_all)
      add :uploader_id, :binary_id, null: false
      add :alt, :text, null: false, default: ""
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :source, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:images, [:project_id])

    create constraint(:images, :images_type,
             check: "content_type IN ('image/png','image/jpeg','image/webp','image/svg+xml')"
           )

    create constraint(:images, :images_size, check: "byte_size > 0 AND byte_size <= 2097152")
    create constraint(:images, :images_source, check: "source IN ('upload','demo')")

    create table(:generations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :lesson_id, references(:lessons, type: :binary_id, on_delete: :nilify_all)
      add :user_id, :binary_id, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :cost, :integer, null: false
      add :provider, :string, null: false
      add :model, :string
      add :brief, :text, null: false
      add :result, :map
      add :error, :string
      # state of the billing reservation "studio:gen:<id>"
      add :credits, :string, null: false, default: "reserved"
      add :retry_of, :binary_id
      add :applied_at, :utc_datetime
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:generations, [:project_id, :inserted_at])
    create index(:generations, [:user_id, :inserted_at])

    create constraint(:generations, :generations_kind,
             check: "kind IN ('outline','lesson_draft','feedback','image')"
           )

    create constraint(:generations, :generations_status,
             check: "status IN ('pending','running','succeeded','failed','cancelled')"
           )

    create constraint(:generations, :generations_credits,
             check: "credits IN ('reserved','consumed','released')"
           )

    create table(:member_settings, primary_key: false) do
      add :user_id, :binary_id, primary_key: true
      # consent: share my drafts with an external AI provider (off by default)
      add :share_drafts_with_ai, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end
  end
end
