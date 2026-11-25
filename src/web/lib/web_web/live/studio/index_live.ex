defmodule MysticWeb.Studio.IndexLive do
  @moduledoc "Studio home: my projects and those shared with me, links to the AI credits and, for staff, the review queue."
  use MysticWeb, :live_view
  import MysticWeb.StudioComponents

  @impl true
  def mount(_params, _session, socket) do
    projects =
      case Api.get(socket, :studio, "/api/projects") do
        {:ok, %{"owned" => owned, "shared" => shared}} -> %{owned: owned, shared: shared}
        _ -> :unavailable
      end

    {:ok, assign(socket, page_title: gettext("Studio"), projects: projects)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:studio}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Create")} title={gettext("Studio")}>
          {gettext("Write your own adventures: plan, draft, review and publish them to the academy.")}
          <:actions>
            <.button navigate={~p"/studio/new"} id="new-project"><.icon name="hero-plus" /> {gettext(
              "New project"
            )}</.button>
            <.button navigate={~p"/studio/credits"} variant="secondary" id="credits-link">
              <.icon name="hero-bolt" /> {gettext("AI credits")}
            </.button>
            <.button
              :if={@current_user["role"] in ["moderator", "admin"]}
              navigate={~p"/studio/review"}
              variant="ghost"
              id="review-link"
            >
              {gettext("Review queue")}
            </.button>
          </:actions>
        </.page_header>

        <%= case @projects do %>
          <% :unavailable -> %>
            <.unavailable id="projects-unavailable">
              {gettext("Your projects can't be loaded right now.")}
            </.unavailable>
          <% %{owned: [], shared: []} -> %>
            <.empty_state id="no-projects" icon="hero-pencil-square" title={gettext("No project yet")}>
              {gettext("Start with a brief: a title, what learners will be able to do, and for whom.")}
              <:actions>
                <.button navigate={~p"/studio/new"}>{gettext("Start a project")}</.button>
              </:actions>
            </.empty_state>
          <% projects -> %>
            <.project_list
              id="owned-projects"
              title={gettext("My projects")}
              projects={projects.owned}
            />
            <.project_list
              id="shared-projects"
              title={gettext("Shared with me")}
              projects={projects.shared}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :projects, :list, required: true

  defp project_list(assigns) do
    ~H"""
    <section :if={@projects != []} class="space-y-4" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="text-3xl">{@title}</h2>
      <ul id={@id} class="grid gap-4 md:grid-cols-2">
        <li
          :for={project <- @projects}
          id={"project-#{project["id"]}"}
          class="card studio-project-card"
        >
          <div class="flex flex-wrap items-center gap-2">
            <.status_tag status={project["status"]} />
            <.tag>{role_label(project["role"])}</.tag>
            <.tag>{category_label(project["category"])}</.tag>
          </div>
          <h3 class="text-2xl">
            <.link navigate={~p"/studio/#{project["id"]}"} class="card-link">{project["title"]}</.link>
          </h3>
          <p class="text-sm text-muted">
            {ngettext("%{count} module", "%{count} modules", project["modules_count"])} · {ngettext(
              "%{count} lesson",
              "%{count} lessons",
              project["lessons_count"]
            )} · {gettext("updated %{date}", date: date(project["updated_at"]))}
          </p>
        </li>
      </ul>
    </section>
    """
  end
end
