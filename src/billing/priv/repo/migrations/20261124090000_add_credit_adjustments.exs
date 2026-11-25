defmodule MlBilling.Repo.Migrations.AddCreditAdjustments do
  use Ecto.Migration

  # Ajustement manuel de crédits IA par un admin.
  def up do
    drop constraint(:credit_entries, :credit_entry_kind)

    create constraint(:credit_entries, :credit_entry_kind,
             check:
               "kind IN ('allocation','top_up','reservation','consumption','release','expiration','adjustment')"
           )

    create index(:webhook_events, [:status, :inserted_at])
  end

  def down do
    drop index(:webhook_events, [:status, :inserted_at])
    drop constraint(:credit_entries, :credit_entry_kind)

    create constraint(:credit_entries, :credit_entry_kind,
             check:
               "kind IN ('allocation','top_up','reservation','consumption','release','expiration')"
           )
  end
end
