defmodule MlStudio.NotifyWorker do
  @moduledoc """
  Notifie une décision de revue au propriétaire et aux éditeurs du projet, sans titre ni motif.
  """
  use Oban.Worker, queue: :notify, max_attempts: 10
  import Ecto.Query
  alias MlStudio.Projects.{Collaborator, Project}

  @doc "Tâches de notification de la décision `kind` sur `project` (dans la transaction de la décision)."
  def enqueue!(%Project{} = project, kind) when kind in ~w(review_approved review_rejected) do
    editors =
      MlStudio.Repo.all(
        from c in Collaborator,
          where: c.project_id == ^project.id and c.role == "editor",
          select: c.user_id
      )

    key =
      "project:#{project.id}:review:#{project.review_version}:#{DateTime.to_unix(project.reviewed_at)}"

    for user_id <- Enum.uniq(Enum.reject([project.owner_id | editors], &is_nil/1)) do
      %{
        user_id: user_id,
        category: "studio",
        kind: kind,
        params: %{project_id: project.id},
        dedupe_key: key
      }
      |> new()
      |> Oban.insert!()
    end

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: notification}) do
    case MlShared.Notifications.deliver(notification) do
      :ok -> :ok
      {:discard, reason} -> {:cancel, inspect(reason)}
      {:retry, reason} -> {:error, reason}
    end
  end
end
