defmodule MlAccounts.Repo.Migrations.AddAccountSecurity do
  use Ecto.Migration

  # Uniquement additive (colonnes facultatives, nouvelles tables) : le code précédent fonctionne sur une base migrée.
  def change do
    # 2FA TOTP : secrets chiffrés au repos (AES-256-GCM), dernier pas de temps accepté (anti-rejeu).
    alter table(:users) do
      add :totp_secret, :binary
      add :totp_pending_secret, :binary
      add :totp_last_step, :bigint
      add :totp_enabled_at, :utc_datetime
    end

    # Sessions actives : user agent tronqué et IP anonymisée, enregistrés à la connexion.
    alter table(:sessions) do
      add :user_agent, :string, size: 200
      add :ip, :string, size: 45
    end

    # Jetons envoyés par e-mail, à usage unique (réinitialisation, changement d'e-mail) : SHA-256 seulement.
    create table(:user_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :context, :string, null: false
      add :token_hash, :binary, null: false
      add :sent_to, :citext, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_tokens, [:token_hash])
    create index(:user_tokens, [:user_id, :context])

    create constraint(:user_tokens, :context_must_be_valid,
             check: "context IN ('reset_password', 'change_email')"
           )

    # Codes de récupération : usage unique (supprimés à l'emploi), SHA-256 de l'id du membre + code.
    create table(:recovery_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :binary, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:recovery_codes, [:user_id, :code_hash])

    # Second facteur à la connexion : challenge court (5 minutes, 5 essais) émis après un mot de passe correct.
    create table(:login_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :attempts, :integer, null: false, default: 0
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:login_challenges, [:token_hash])
    create index(:login_challenges, [:user_id])

    # Compteurs à fenêtre glissante par clé (mots de passe / codes erronés, demandes de changement d'e-mail).
    create table(:throttle_events) do
      add :key, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:throttle_events, [:key, :inserted_at])
  end
end
