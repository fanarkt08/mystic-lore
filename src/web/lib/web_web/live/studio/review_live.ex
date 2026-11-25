defmodule MysticWeb.Studio.ReviewLive do
  @moduledoc "Staff review of the submitted projects."
  use MysticWeb, :live_view
  import MysticWeb.StudioComponents

  # like the /admin pages, a member without the staff role gets the themed 403 page (studio checks the role
  # again on every call: its own 403, if the role changed meanwhile, stays an inline state)
  on_mount {MysticWeb.Admin.Guard, :staff}

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         page_title: gettext("Review queue"),
         topic: nil,
         reject_form: to_form(%{"reason" => ""})
       )}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket),
    do: {:noreply, socket |> assign(id: id) |> load_review(true)}

  def handle_params(_params, _uri, socket), do: {:noreply, load_queue(socket)}

  defp load_queue(socket) do
    case Api.get(socket, :studio, "/api/moderation/queue") do
      {:ok, %{"projects" => projects}} ->
        assign(socket, queue: projects, owners: owners(socket, projects))

      {:error, {:http, 403, _}} ->
        assign(socket, queue: :forbidden)

      _ ->
        assign(socket, queue: :unavailable)
    end
  end

  defp load_review(socket, subscribe?) do
    case Api.get(socket, :studio, "/api/moderation/projects/:id",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"project" => project} = review} ->
        if subscribe? and connected?(socket) and is_nil(socket.assigns.topic) do
          MlShared.Events.subscribe("studio:project:#{project["id"]}")
          # subscribed: load again so that no change is missed in between
          socket |> assign(topic: true) |> load_review(false)
        else
          assign(socket,
            review: review,
            owners: owners(socket, [project]),
            page_title: project["title"]
          )
        end

      {:error, {:http, 403, _}} ->
        assign(socket, review: :forbidden)

      {:error, {:http, 404, _}} ->
        assign(socket, review: :not_found)

      _ ->
        assign(socket, review: :unavailable)
    end
  end

  # Public names of the authors (accounts), best effort.
  defp owners(socket, projects) do
    ids = projects |> Enum.map(& &1["owner_id"]) |> Enum.uniq()

    case ids != [] && Api.get(socket, :accounts, "/api/users", params: [ids: Enum.join(ids, ",")]) do
      {:ok, %{"users" => users}} -> Map.new(users, &{&1["id"], &1})
      _ -> %{}
    end
  end

  @impl true
  def handle_info({:studio_project, _project_id, _change}, socket),
    do: {:noreply, load_review(socket, false)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approve", _params, socket) do
    case Api.post(socket, :studio, "/api/moderation/projects/:id/approve",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_review(false)
         |> put_flash(
           :info,
           gettext("Approved: the adventure is being imported into the catalog.")
         )}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("reject", %{"reason" => reason}, socket) do
    case Api.post(socket, :studio, "/api/moderation/projects/:id/reject",
           path_params: [id: socket.assigns.id],
           json: %{reason: reason}
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Rejected: the author can see your reason."))
         |> push_navigate(to: ~p"/studio/review")}

      error ->
        errors = Api.form_errors(error, [:reason])

        socket =
          if errors == [], do: put_flash(socket, :error, error_message(error)), else: socket

        {:noreply,
         assign(socket,
           reject_form: to_form(%{"reason" => reason}, errors: errors, action: :validate)
         )}
    end
  end

  def handle_event("retry_import", _params, socket) do
    case Api.post(socket, :studio, "/api/moderation/projects/:id/retry-import",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, gettext("The import will be tried again."))}
      error -> {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  defp author(owners, id), do: get_in(owners, [id, "display_name"]) || gettext("A member")

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:studio}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Studio")} title={gettext("Review queue")}>
          {gettext(
            "Projects submitted by authors. You review the submitted version; you can't review a project you wrote."
          )}
        </.page_header>
        <%= case @queue do %>
          <% :forbidden -> %>
            <.notice id="review-forbidden" kind="warning">
              {gettext("Only moderators and admins can review projects.")}
            </.notice>
          <% :unavailable -> %>
            <.unavailable>{gettext("The review queue can't be loaded right now.")}</.unavailable>
          <% [] -> %>
            <.empty_state
              id="queue-empty"
              icon="hero-check-badge"
              title={gettext("Nothing to review")}
            />
          <% projects -> %>
            <ul class="space-y-3" id="review-queue">
              <li
                :for={p <- projects}
                id={"queued-#{p["id"]}"}
                class="card flex flex-wrap items-center gap-3"
              >
                <.status_tag status={p["status"]} />
                <.link navigate={~p"/studio/review/#{p["id"]}"} class="link text-xl">{p["title"]}</.link>
                <span class="text-sm text-muted">{gettext("by %{name}, submitted %{date}",
                  name: author(@owners, p["owner_id"]),
                  date: date(p["submitted_at"])
                )}</span>
              </li>
            </ul>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

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
        <.link navigate={~p"/studio/review"} class="link text-sm">← {gettext("Review queue")}</.link>
        <%= case @review do %>
          <% :forbidden -> %>
            <.notice id="review-forbidden" kind="warning">
              {gettext("Only moderators and admins can review projects.")}
            </.notice>
          <% :not_found -> %>
            <.notice id="review-gone" kind="info">
              {gettext("This project is no longer in review.")}
            </.notice>
          <% :unavailable -> %>
            <.unavailable>{gettext("This review can't be loaded right now.")}</.unavailable>
          <% %{"project" => project, "version" => version} = review -> %>
            <.page_header
              eyebrow={gettext("Submitted version %{n}", n: version["number"])}
              title={project["title"]}
            >
              {gettext("by %{name}", name: author(@owners, project["owner_id"]))} · {project[
                "summary"
              ]}
            </.page_header>
            <div class="flex flex-wrap items-center gap-2">
              <.status_tag status={project["status"]} id="review-status" />
            </div>

            <.notice
              :if={project["status"] == "approved"}
              id="import-status"
              kind="info"
              title={gettext("Approved: publishing to the catalog")}
            >
              {get_in(project, ["publication", "message"]) ||
                gettext("The import into the learning catalog is in progress.")}
              <:actions :if={get_in(project, ["publication", "message"])}>
                <.button phx-click="retry_import" variant="secondary" id="retry-import">{gettext(
                  "Retry the import"
                )}</.button>
              </:actions>
            </.notice>

            <.notice
              :if={project["status"] == "published"}
              id="review-published"
              kind="success"
              title={gettext("Published")}
            >
              <.link href={~p"/adventures/#{project["publication"]["slug"]}"} class="link">{gettext(
                "Open the published adventure"
              )}</.link>
            </.notice>

            <section class="card space-y-4" aria-labelledby="review-checks-title">
              <h2 id="review-checks-title" class="text-2xl">{gettext("Automatic checks")}</h2>
              <.check_list checks={review["checks"]} />
            </section>

            <section
              class="card space-y-2"
              aria-labelledby="review-declarations-title"
              id="review-declarations"
            >
              <h2 id="review-declarations-title" class="text-2xl">
                {gettext("Author's declarations")}
              </h2>
              <p class="text-sm text-muted">
                {gettext("Declared by the author, not verified automatically.")}
              </p>
              <ul class="space-y-1 text-sm">
                <li :for={
                  {key, label} <- [
                    {"accuracy", gettext("Accurate content")},
                    {"safety", gettext("Safe and kind content")},
                    {"accessibility", gettext("Accessible content")}
                  ]
                }>
                  <.icon
                    name={
                      if (review["attestations"] || %{})[key], do: "hero-check", else: "hero-x-mark"
                    }
                    class="size-4"
                  /> {label}
                </li>
              </ul>
            </section>

            <section class="card space-y-4" aria-labelledby="snapshot-title" id="snapshot">
              <h2 id="snapshot-title" class="text-2xl">{gettext("Submitted content")}</h2>
              <ul class="list-disc pl-5 text-sm">
                <li :for={o <- version["snapshot"]["brief"]["objectives"]}>{o}</li>
              </ul>
              <div
                :for={{module, i} <- Enum.with_index(version["snapshot"]["modules"], 1)}
                class="space-y-3"
              >
                <h3 class="text-xl">
                  {gettext("Chapter %{n}: %{title}", n: i, title: module["title"])}
                </h3>
                <div :for={lesson <- module["lessons"]} class="space-y-1">
                  <.lesson_preview
                    lesson={lesson}
                    project_id={project["id"]}
                    images={
                      Enum.filter(version["snapshot"]["images"], &(&1["lesson_id"] == lesson["id"]))
                    }
                  />
                  <p
                    :if={lesson["kind"] == "exercise"}
                    class="text-sm text-success"
                    id={"answer-#{lesson["id"]}"}
                  >
                    {gettext("Correct answer: %{choice}",
                      choice:
                        Enum.at(lesson["content"]["choices"] || [], lesson["content"]["answer"] || -1) ||
                          "—"
                    )}
                  </p>
                </div>
              </div>
            </section>

            <section
              :if={project["status"] == "submitted"}
              class="card space-y-4"
              aria-labelledby="decision-title"
              id="decision"
            >
              <h2 id="decision-title" class="text-2xl">{gettext("Decision")}</h2>
              <.button
                phx-click="approve"
                id="approve"
                data-confirm={gettext("Approve and publish this version?")}
              >{gettext("Approve and publish")}</.button>
              <.form for={@reject_form} id="reject-form" phx-submit="reject" class="space-y-3">
                <.input
                  field={@reject_form[:reason]}
                  type="textarea"
                  rows="3"
                  maxlength="1000"
                  label={gettext("Reason for the author (required to reject)")}
                  required
                />
                <.button type="submit" variant="danger" id="reject">{gettext("Reject")}</.button>
              </.form>
            </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
