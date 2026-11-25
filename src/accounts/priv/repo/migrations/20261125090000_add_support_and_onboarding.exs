defmodule MlAccounts.Repo.Migrations.AddSupportAndOnboarding do
  use Ecto.Migration

  # Demandes de support et état de l'accueil guidé. Uniquement additive.
  def change do
    # Les comptes déjà créés sont marqués `completed` : seul un nouveau compte voit l'accueil guidé.
    alter table(:users) do
      add :onboarding_status, :string, null: false, default: "pending"
      add :onboarding_at, :utc_datetime
    end

    execute(
      "UPDATE users SET onboarding_status = 'completed', onboarding_at = now()",
      "SELECT 1"
    )

    create constraint(:users, :users_onboarding_status,
             check: "onboarding_status IN ('pending', 'completed', 'skipped')"
           )

    # Demande d'un membre (`user_id`) ou d'un visiteur (`email`), supprimée avec le compte du membre.
    create table(:support_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reference, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :email, :string
      add :topic, :string, null: false
      add :message, :text, null: false
      add :locale, :string, null: false, default: "en"
      add :status, :string, null: false, default: "open"
      add :internal_note, :text
      add :answered_at, :utc_datetime
      add :closed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:support_requests, [:reference])
    create index(:support_requests, [:user_id])
    create index(:support_requests, [:status, :inserted_at])
    create index(:support_requests, [:closed_at])

    create constraint(:support_requests, :support_requests_status,
             check: "status IN ('open', 'answered', 'closed')"
           )

    create constraint(:support_requests, :support_requests_topic,
             check: "topic IN ('account', 'billing', 'privacy', 'bug', 'other')"
           )

    create constraint(:support_requests, :support_requests_requester,
             check: "(user_id IS NULL) <> (email IS NULL)"
           )

    # Réponses du staff (envoyées par e-mail par accounts) ; `email_status` : remise au Mailer réussie ou non.
    create table(:support_replies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :request_id, references(:support_requests, type: :binary_id, on_delete: :delete_all),
        null: false

      add :author_id, :binary_id, null: false
      add :body, :text, null: false
      add :email_status, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:support_replies, [:request_id])
  end
end
