defmodule MlAccounts.Repo do
  use Ecto.Repo,
    otp_app: :accounts,
    adapter: Ecto.Adapters.Postgres
end
