defmodule MlStudio.AI.GenerationWorker do
  @moduledoc """
  Oban job that runs one generation; a finished or cancelled generation is never run again.
  """
  use Oban.Worker, queue: :ai, max_attempts: 3
  alias MlStudio.AI
  alias MlStudio.AI.Generation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"generation_id" => id}} = job) do
    case MlStudio.Repo.get(Generation, id) do
      %Generation{status: status} = generation when status in ["pending", "running"] ->
        AI.run(generation, job.attempt >= job.max_attempts)

      _done_or_cancelled ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 10 * attempt

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)
end
