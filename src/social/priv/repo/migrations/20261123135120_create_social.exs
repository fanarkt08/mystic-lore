defmodule MlSocial.Repo.Migrations.CreateSocial do
  use Ecto.Migration

  # Les membres vivent dans la base d'accounts : leurs UUID sont stockés ici sans clé étrangère.
  def change do
    create table(:friendships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :requester_id, :binary_id, null: false
      add :addressee_id, :binary_id, null: false
      add :status, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:friendships, :friendships_not_self, check: "requester_id <> addressee_id")

    create constraint(:friendships, :friendships_status,
             check: "status IN ('pending', 'accepted')"
           )

    # Paire non ordonnée unique : (a, b) et (b, a) désignent la même relation.
    create unique_index(
             :friendships,
             ["LEAST(requester_id, addressee_id)", "GREATEST(requester_id, addressee_id)"],
             name: :friendships_pair_index
           )

    create index(:friendships, [:requester_id, :status])
    create index(:friendships, [:addressee_id, :status])

    create table(:blocks, primary_key: false) do
      add :blocker_id, :binary_id, primary_key: true
      add :blocked_id, :binary_id, primary_key: true
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:blocks, :blocks_not_self, check: "blocker_id <> blocked_id")
    create index(:blocks, [:blocked_id])

    # Conversation directe : une seule par paire (user_low < user_high).
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_low, :binary_id, null: false
      add :user_high, :binary_id, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:conversations, :conversations_ordered_pair, check: "user_low < user_high")
    create unique_index(:conversations, [:user_low, :user_high])

    create table(:conversation_members, primary_key: false) do
      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :user_id, :binary_id, primary_key: true
      add :last_read_at, :utc_datetime_usec
    end

    create index(:conversation_members, [:user_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sender_id, :binary_id, null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:messages, :messages_body_length,
             check: "char_length(body) BETWEEN 1 AND 2000"
           )

    create index(:messages, [:conversation_id, :inserted_at, :id])

    # Pas de clé étrangère vers messages : l'instantané doit survivre au message signalé.
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reporter_id, :binary_id, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :reason, :string, null: false
      add :details, :text
      add :message_body, :text
      add :message_sender_id, :binary_id
      add :message_sent_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:reports, :reports_target_type, check: "target_type IN ('user', 'message')")

    create constraint(:reports, :reports_reason,
             check: "reason IN ('harassment', 'spam', 'inappropriate', 'other')"
           )

    create index(:reports, [:target_type, :target_id])
  end
end
