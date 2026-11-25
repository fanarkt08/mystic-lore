defmodule MlSocial.Repo.Migrations.AddGroupsAttachmentsSettings do
  use Ecto.Migration

  # Groupes, messages système, sourdine, pièces jointes et réglages de confidentialité.
  def up do
    alter table(:conversations) do
      add :kind, :string, null: false, default: "direct"
      add :name, :string
      add :owner_id, :binary_id
      modify :user_low, :binary_id, null: true
      modify :user_high, :binary_id, null: true
    end

    drop constraint(:conversations, :conversations_ordered_pair)

    # direct : paire ordonnée, sans nom ; groupe : nom de 1 à 60 caractères et propriétaire, sans paire
    create constraint(:conversations, :conversations_shape,
             check: """
             (kind = 'direct' AND user_low IS NOT NULL AND user_high IS NOT NULL AND user_low < user_high
               AND name IS NULL AND owner_id IS NULL)
             OR (kind = 'group' AND user_low IS NULL AND user_high IS NULL AND owner_id IS NOT NULL
               AND char_length(name) BETWEEN 1 AND 60)
             """
           )

    alter table(:conversation_members) do
      # ancienneté (transfert de la propriété d'un groupe) ; sourdine (« toujours » = 9999-12-31)
      add :joined_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :muted_until, :utc_datetime_usec
    end

    alter table(:messages) do
      add :kind, :string, null: false, default: "text"
      # message système : %{"event", "actor_id", "target_id", "name"}
      add :system, :map
      modify :body, :text, null: true
    end

    drop constraint(:messages, :messages_body_length)

    create constraint(:messages, :messages_body_length,
             check: "body IS NULL OR char_length(body) BETWEEN 1 AND 2000"
           )

    create constraint(:messages, :messages_kind,
             check:
               "(kind = 'text' AND system IS NULL) OR (kind = 'system' AND system IS NOT NULL AND body IS NULL)"
           )

    # Une pièce jointe par message au plus ; `erased_at` garde la ligne quand le fichier est effacé.
    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :uploader_id, :binary_id, null: false
      add :kind, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :width, :integer
      add :height, :integer
      add :filename, :string
      add :alt_text, :text
      add :scan, :string, null: false
      add :storage_key, :string
      add :erased_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:attachments, [:message_id])
    create unique_index(:attachments, [:storage_key])
    create index(:attachments, [:uploader_id])

    create constraint(:attachments, :attachments_kind,
             check: "kind IN ('image', 'pdf') AND scan IN ('clean', 'unscanned')"
           )

    create constraint(:attachments, :attachments_text,
             check: "char_length(alt_text) <= 300 AND char_length(filename) <= 120"
           )

    alter table(:reports) do
      # pièce jointe du message signalé (le fichier n'est pas copié : il reste celui du message)
      add :message_attachment_id, :binary_id
    end

    # Réglages de confidentialité (statut en ligne, accusés de lecture, permissions de contact) ; ligne absente =
    # valeurs par défaut.
    create table(:settings, primary_key: false) do
      add :user_id, :binary_id, primary_key: true
      add :show_online, :boolean, null: false, default: true
      add :read_receipts, :boolean, null: false, default: true
      add :friend_requests, :string, null: false, default: "everyone"
      add :group_adds, :string, null: false, default: "friends"
      add :lobby_invites, :string, null: false, default: "friends"
      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end

    create constraint(:settings, :settings_values,
             check: """
             friend_requests IN ('everyone', 'friends_of_friends', 'nobody')
             AND group_adds IN ('friends', 'nobody') AND lobby_invites IN ('friends', 'nobody')
             """
           )
  end

  def down do
    drop table(:settings)

    alter table(:reports) do
      remove :message_attachment_id
    end

    drop table(:attachments)
    execute "DELETE FROM messages WHERE kind = 'system' OR body IS NULL"
    drop constraint(:messages, :messages_kind)
    drop constraint(:messages, :messages_body_length)

    create constraint(:messages, :messages_body_length,
             check: "char_length(body) BETWEEN 1 AND 2000"
           )

    alter table(:messages) do
      remove :kind
      remove :system
      modify :body, :text, null: false
    end

    alter table(:conversation_members) do
      remove :joined_at
      remove :muted_until
    end

    execute "DELETE FROM conversations WHERE kind = 'group'"
    drop constraint(:conversations, :conversations_shape)

    alter table(:conversations) do
      remove :kind
      remove :name
      remove :owner_id
      modify :user_low, :binary_id, null: false
      modify :user_high, :binary_id, null: false
    end

    create constraint(:conversations, :conversations_ordered_pair, check: "user_low < user_high")
  end
end
