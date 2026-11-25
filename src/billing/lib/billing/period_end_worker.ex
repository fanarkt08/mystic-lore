defmodule MlBilling.PeriodEndWorker do
  @moduledoc "Cron job that ends or renews the local demo subscriptions whose period is over."
  use Oban.Worker, queue: :default, max_attempts: 3
  import Ecto.Query
  alias MlBilling.{Local, Repo, Subscription}

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now(:second)

    from(s in Subscription,
      where:
        s.provider == "local" and s.status in ["active", "past_due"] and
          s.current_period_end <= ^now
    )
    |> Repo.all()
    |> Enum.map(&Local.end_period/1)
    |> Enum.find(:ok, &(&1 != :ok))
  end
end
