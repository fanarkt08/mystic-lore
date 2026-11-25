defmodule MlAccounts.Support.PurgeWorker do
  @moduledoc """
  Purge quotidienne des demandes de support (`MlAccounts.Support.purge/1`). Seul le nombre de demandes
  supprimées est journalisé, jamais leur contenu.
  """
  use Oban.Worker, queue: :privacy, max_attempts: 3
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = MlAccounts.Support.purge()
    if count > 0, do: Logger.info("support: #{count} request(s) purged (retention)")
    :ok
  end
end
