defmodule MlStudio.Events do
  @moduledoc "Real-time events of a project, which `web` subscribes to only after an access check."
  alias MlStudio.AI.Generation
  alias MlStudio.Projects.Project

  def topic(project_id), do: "studio:project:#{project_id}"

  def project_changed(%Project{} = p, by) do
    MlShared.Events.broadcast(
      topic(p.id),
      {:studio_project, p.id,
       %{"by" => by, "revision" => p.content_revision, "status" => p.status}}
    )
  end

  def generation(%Generation{} = g),
    do:
      MlShared.Events.broadcast(
        topic(g.project_id),
        {:studio_generation, g.project_id, MlStudio.View.generation(g)}
      )
end
