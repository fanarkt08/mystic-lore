defmodule MlStudio.AI.SettleWorker do
  @moduledoc "Oban job that consumes or releases the billing reservation of a finished generation, exactly once."
  use Oban.Worker, queue: :credits, max_attempts: 20
  alias MlStudio.AI
  alias MlStudio.AI.Generation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"generation_id" => id}}) do
    case MlStudio.Repo.get(Generation, id) do
      %Generation{credits: "reserved", status: status} = generation
      when status in ["succeeded", "failed", "cancelled"] ->
        AI.settle(generation)

      _ ->
        :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(5 * Integer.pow(2, attempt), 900)
end
