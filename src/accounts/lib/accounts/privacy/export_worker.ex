defmodule MlAccounts.Privacy.ExportWorker do
  @moduledoc "Tâche Oban qui assemble un export de données et le marque `failed` au dernier essai."
  use Oban.Worker, queue: :privacy, max_attempts: 6

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => id}, attempt: attempt, max_attempts: max}),
    do: MlAccounts.Privacy.build_export(id, attempt >= max)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(15 * Integer.pow(2, attempt - 1), 300)
end
