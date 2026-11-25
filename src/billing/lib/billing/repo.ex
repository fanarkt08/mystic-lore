defmodule MlBilling.Repo do
  use Ecto.Repo,
    otp_app: :billing,
    adapter: Ecto.Adapters.Postgres
end
