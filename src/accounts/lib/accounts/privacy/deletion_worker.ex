defmodule MlAccounts.Privacy.DeletionWorker do
  @moduledoc "Tâche Oban qui exécute la suppression due d'un membre, une seule à la fois par membre."
  use Oban.Worker,
    queue: :privacy,
    max_attempts: 20,
    unique: [keys: [:user_id], states: :incomplete, period: :infinity]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}),
    do: MlAccounts.Privacy.execute_deletion(user_id)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(30 * Integer.pow(2, attempt - 1), 3600)
end
