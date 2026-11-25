defmodule MlMultiplayer.Repo.Migrations.CreateMultiplayer do
  use Ecto.Migration

  # Les membres vivent dans la base d'accounts : leurs UUID sont stockés ici sans clé étrangère.
  def change do
    create table(:lobbies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :host_id, :binary_id, null: false
      add :title, :string, null: false
      add :visibility, :string, null: false
      add :requires_approval, :boolean, null: false, default: false
      add :max_players, :integer, null: false
      add :starts_at, :utc_datetime_usec
      add :status, :string, null: false, default: "waiting"
      add :current_match_id, :binary_id
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:lobbies, :lobbies_visibility, check: "visibility IN ('open', 'private')")

    create constraint(:lobbies, :lobbies_status,
             check: "status IN ('waiting', 'playing', 'closed')"
           )

    create constraint(:lobbies, :lobbies_capacity, check: "max_players BETWEEN 2 AND 4")
    create constraint(:lobbies, :lobbies_title, check: "char_length(title) BETWEEN 3 AND 60")
    create index(:lobbies, [:visibility, :status, :inserted_at])
    create index(:lobbies, [:host_id, :status])

    # Une ligne par (salon, membre) : demande en attente, membre actif, parti, exclu (bannissement) ou refusé.
    create table(:lobby_members, primary_key: false) do
      add :lobby_id, references(:lobbies, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :user_id, :binary_id, primary_key: true
      add :status, :string, null: false
      add :ready, :boolean, null: false, default: false

      # état de connexion dérivé des battements (`last_seen_at`, source de vérité), tenu par le Sweeper
      add :connection, :string, null: false, default: "online"
      add :last_seen_at, :utc_datetime_usec, null: false
      add :joined_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:lobby_members, :lobby_members_status,
             check: "status IN ('pending', 'active', 'left', 'kicked', 'declined')"
           )

    create constraint(:lobby_members, :lobby_members_connection,
             check: "connection IN ('online', 'disconnected', 'absent')"
           )

    create index(:lobby_members, [:user_id, :status])
    create index(:lobby_members, [:status, :connection, :last_seen_at])

    create table(:lobby_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lobby_id, references(:lobbies, type: :binary_id, on_delete: :delete_all), null: false

      add :inviter_id, :binary_id, null: false
      add :invitee_id, :binary_id, null: false
      add :status, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:lobby_invites, :lobby_invites_status,
             check: "status IN ('pending', 'accepted', 'declined', 'revoked')"
           )

    create constraint(:lobby_invites, :lobby_invites_not_self, check: "inviter_id <> invitee_id")
    create unique_index(:lobby_invites, [:lobby_id, :invitee_id])
    create index(:lobby_invites, [:invitee_id, :status])

    # Lien temporaire : seul le SHA-256 du jeton est stocké (le jeton n'est montré qu'à la création).
    create table(:lobby_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lobby_id, references(:lobbies, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by, :binary_id, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :max_uses, :integer, null: false
      add :uses, :integer, null: false, default: 0
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:lobby_links, [:token_hash])
    create index(:lobby_links, [:lobby_id])

    create constraint(:lobby_links, :lobby_links_uses,
             check: "max_uses BETWEEN 1 AND 20 AND uses BETWEEN 0 AND max_uses"
           )

    create table(:lobby_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lobby_id, references(:lobbies, type: :binary_id, on_delete: :delete_all), null: false

      add :user_id, :binary_id, null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:lobby_messages, :lobby_messages_body,
             check: "char_length(body) BETWEEN 1 AND 500"
           )

    create index(:lobby_messages, [:lobby_id, :inserted_at, :id])
    create index(:lobby_messages, [:lobby_id, :user_id, :inserted_at])

    create table(:matches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lobby_id, references(:lobbies, type: :binary_id, on_delete: :delete_all), null: false

      add :status, :string, null: false, default: "active"
      # dernier numéro de séquence écrit dans match_events (contrôle d'écriture concurrente)
      add :last_seq, :integer, null: false, default: 0
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:matches, :matches_status,
             check: "status IN ('active', 'won', 'lost', 'aborted')"
           )

    create index(:matches, [:lobby_id, :inserted_at])
    create index(:matches, [:status])

    # Journal de la partie : séquence sans trou ni doublon ; l'état se reconstruit par rejeu.
    create table(:match_events, primary_key: false) do
      add :match_id, references(:matches, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :seq, :integer, primary_key: true
      add :type, :string, null: false
      add :user_id, :binary_id
      add :payload, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:match_events, :match_events_seq, check: "seq >= 1")

    # Récompense XP à livrer à learning : une ligne par (partie, joueur) au plus, rejouée tant qu'elle est en attente.
    create table(:match_rewards, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :match_id, references(:matches, type: :binary_id, on_delete: :delete_all), null: false

      add :user_id, :binary_id, null: false
      add :amount, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec, null: false
      add :last_error, :string
      add :awarded_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:match_rewards, [:match_id, :user_id])
    create index(:match_rewards, [:status, :next_attempt_at])

    create constraint(:match_rewards, :match_rewards_status,
             check: "status IN ('pending', 'awarded', 'failed')"
           )
  end
end
