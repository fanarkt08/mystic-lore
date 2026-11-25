defmodule MlAccounts.Privacy.SweepWorker do
  @moduledoc "Balayage périodique (cron, toutes les 5 minutes) : suppressions dues mises en file, exports expirés purgés."
  use Oban.Worker, queue: :privacy, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    MlAccounts.Privacy.enqueue_due_deletions()
    MlAccounts.Privacy.purge_expired_exports()
    :ok
  end
end
