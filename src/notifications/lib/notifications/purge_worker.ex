defmodule MlNotifications.PurgeWorker do
  @moduledoc """
  Rétention, en cron quotidien : notifications dont le dernier événement a plus de 90 jours, plafond de 500 par
  membre, et nettoyage des occurrences, marques de lecture, journal des e-mails et e-mails reportés anciens.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    MlNotifications.Inbox.purge(DateTime.utc_now())
    :ok
  end
end
