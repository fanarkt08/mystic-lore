defmodule MlBilling.Repo.Migrations.CreateCredits do
  use Ecto.Migration

  def change do
    # One row per user, locked by every credit operation (users live in accounts: no foreign key).
    create table(:credit_accounts, primary_key: false) do
      add :user_id, :binary_id, primary_key: true
      # "YYYY-MM" (UTC) of the current allocation; nil until the first one
      add :period, :string
      add :plan, :string
      add :allocation, :integer, null: false, default: 0
      add :balance, :integer, null: false, default: 0
      add :reserved, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create constraint(:credit_accounts, :credit_balance_non_negative, check: "balance >= 0")
    create constraint(:credit_accounts, :credit_reserved_non_negative, check: "reserved >= 0")
    create constraint(:credit_accounts, :credit_allocation_non_negative, check: "allocation >= 0")

    # Append-only ledger; (user_id, kind, ref) unique: every operation is idempotent.
    create table(:credit_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # total order of the ledger (timestamps can be equal)
      add :seq, :bigserial, null: false
      add :user_id, :binary_id, null: false
      add :kind, :string, null: false
      add :amount, :integer, null: false
      add :delta, :integer, null: false
      add :balance_after, :integer, null: false
      add :ref, :string, null: false
      add :reason, :string
      add :period, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:credit_entries, [:user_id, :kind, :ref])
    create index(:credit_entries, [:user_id, :seq])

    create constraint(:credit_entries, :credit_entry_kind,
             check:
               "kind IN ('allocation','top_up','reservation','consumption','release','expiration')"
           )

    create constraint(:credit_entries, :credit_entry_amount, check: "amount > 0")
    create constraint(:credit_entries, :credit_entry_balance, check: "balance_after >= 0")

    # Audit trail: a ledger line is never modified.
    execute(
      """
      CREATE FUNCTION credit_entries_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'credit_entries rows are immutable';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION credit_entries_immutable()"
    )

    execute(
      """
      CREATE TRIGGER credit_entries_no_update BEFORE UPDATE ON credit_entries
      FOR EACH ROW EXECUTE FUNCTION credit_entries_immutable()
      """,
      "DROP TRIGGER credit_entries_no_update ON credit_entries"
    )
  end
end
