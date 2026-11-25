defmodule MlNotifications.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    # Jamais de texte rédigé, d'URL ni de contenu privé : seulement `kind` et `params`.
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :category, :string, null: false
      add :kind, :string, null: false
      add :actor_id, :binary_id
      add :subject_type, :string
      add :subject_id, :string
      add :params, :map, null: false, default: %{}
      add :dedupe_key, :string, null: false
      add :count, :integer, null: false, default: 1
      add :read_at, :utc_datetime_usec

      # clé de tri : date du dernier événement agrégé (une agrégation remonte la notification en tête)
      add :last_event_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    # au plus une notification non lue par clé et par destinataire (agrégation)
    create unique_index(:notifications, [:user_id, :dedupe_key],
             where: "read_at IS NULL",
             name: :notifications_unread_key_index
           )

    create index(:notifications, [:user_id, "last_event_at DESC", "id DESC"])

    create index(:notifications, [:user_id],
             where: "read_at IS NULL",
             name: :notifications_unread_index
           )

    create index(:notifications, [:actor_id])
    create index(:notifications, [:last_event_at])

    create constraint(:notifications, :count_positive, check: "count >= 1")

    # occurrences déjà traitées (idempotence des nouvelles tentatives des producteurs), purgées après 30 jours
    create table(:notification_events, primary_key: false) do
      add :user_id, :binary_id, primary_key: true
      add :event_id, :string, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:notification_events, [:inserted_at])

    # « lu jusqu'à » par clé : un événement plus ancien arrivé après la lecture ne recrée pas de non-lue.
    create table(:notification_read_marks, primary_key: false) do
      add :user_id, :binary_id, primary_key: true
      add :dedupe_key, :string, primary_key: true
      add :read_at, :utc_datetime_usec, null: false
    end

    create index(:notification_read_marks, [:read_at])

    # préférences par catégorie × canal (seules les valeurs choisies par le membre) et heures calmes, avec le
    # fuseau IANA dans lequel elles s'appliquent
    create table(:notification_settings, primary_key: false) do
      add :user_id, :binary_id, primary_key: true
      add :channels, :map, null: false, default: %{}
      add :quiet_enabled, :boolean, null: false, default: false
      add :quiet_start, :time, null: false, default: "22:00:00"
      add :quiet_end, :time, null: false, default: "07:00:00"
      add :time_zone, :string
      timestamps(type: :utc_datetime_usec)
    end

    # e-mails reportés pendant les heures calmes (un seul résumé à la fin)
    create table(:pending_emails, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :notification_id, :binary_id
      add :category, :string, null: false
      add :kind, :string, null: false
      add :actor_id, :binary_id
      add :params, :map, null: false, default: %{}
      add :dedupe_key, :string, null: false
      add :mandatory, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:pending_emails, [:user_id, :inserted_at])

    # journal des e-mails demandés (limite de débit : par clé et par heure, plafond quotidien), purgé après 2 jours
    create table(:email_log) do
      add :user_id, :binary_id, null: false
      add :dedupe_key, :string, null: false
      add :category, :string, null: false
      add :kind, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :sent_at, :utc_datetime_usec
    end

    create index(:email_log, [:user_id, :inserted_at])
    create index(:email_log, [:user_id, :dedupe_key, :inserted_at])
  end
end
