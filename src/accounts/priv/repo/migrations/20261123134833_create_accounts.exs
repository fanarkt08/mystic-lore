defmodule MlAccounts.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    # citext : unicité et recherches d'e-mail / pseudonyme insensibles à la casse, garanties par la base.
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :username, :citext, null: false
      add :display_name, :string, null: false
      add :bio, :text
      add :hashed_password, :string, null: false
      add :role, :string, null: false, default: "user"
      add :confirmed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:username])

    create constraint(:users, :role_must_be_valid,
             check: "role IN ('user', 'moderator', 'admin')"
           )

    # Jetons stockés uniquement hachés (SHA-256).
    create table(:confirmation_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:confirmation_tokens, [:token_hash])
    create index(:confirmation_tokens, [:user_id])

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:user_id])

    # Une ligne par tentative de connexion échouée (fenêtre glissante de verrouillage, par e-mail).
    create table(:login_failures) do
      add :email, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:login_failures, [:email, :inserted_at])
  end
end
