defmodule MlAccounts.NotifyWorker do
  @moduledoc "Une notification à créer au centre (`MlShared.Notifications.deliver/1`) ; relancée s'il est injoignable."
  use Oban.Worker, queue: :notify, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: notification}) do
    case MlShared.Notifications.deliver(notification) do
      :ok -> :ok
      {:discard, reason} -> {:cancel, inspect(reason)}
      {:retry, reason} -> {:error, reason}
    end
  end
end
