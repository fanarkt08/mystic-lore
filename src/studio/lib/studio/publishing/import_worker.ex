defmodule MlStudio.Publishing.ImportWorker do
  @moduledoc "Oban job that imports an approved version into learning and marks the project `published`."
  use Oban.Worker, queue: :publish, max_attempts: 10
  require Logger
  alias MlStudio.{Publishing, Repo, Services}
  alias MlStudio.Projects.{Project, Version}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => id, "version" => number}} = job) do
    with %Project{status: "approved", review_version: ^number} = project <- Repo.get(Project, id),
         %Version{} = version <- Repo.get_by(Version, project_id: id, number: number) do
      import_version(project, version, job)
    else
      # withdrawn, rejected or already published meanwhile: nothing to import
      _ -> :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(15 * Integer.pow(2, attempt), 3600)

  defp import_version(project, version, job) do
    last? = job.attempt >= job.max_attempts

    retry =
      if last?,
        do: " Automatic retries are over: a moderator can retry the import.",
        else: " It will be retried automatically."

    case Services.import_adventure(Publishing.import_payload(project, version)) do
      {:ok, %{"slug" => slug} = body} when is_binary(slug) ->
        Publishing.import_result(project, {:published, body})
        :ok

      {:error, {:http, status, body}} when status in [403, 409, 422] ->
        Logger.warning("studio import of #{project.id} v#{version.number}: HTTP #{status}")
        Publishing.import_result(project, {:pending, permanent(status, body)})
        {:cancel, "learning answered HTTP #{status}"}

      {:error, {:http, 404, _}} ->
        message = "The learning catalog doesn't accept studio imports yet (HTTP 404)." <> retry
        Publishing.import_result(project, {:pending, message})
        {:error, :import_not_available}

      _unavailable_or_unexpected ->
        message = "The learning catalog is unavailable right now." <> retry
        Publishing.import_result(project, {:pending, message})
        {:error, :learning_unavailable}
    end
  end

  defp permanent(409, _body),
    do: "A newer version of this adventure is already in the catalog (stale version)."

  defp permanent(422, %{"errors" => errors}) when is_map(errors),
    do:
      "The learning catalog refused the content: " <>
        Enum.map_join(errors, "; ", fn {k, v} -> "#{k} #{Enum.join(List.wrap(v), ", ")}" end)

  defp permanent(status, _body),
    do: "The learning catalog refused the import (HTTP #{status}). A moderator can retry it."
end
