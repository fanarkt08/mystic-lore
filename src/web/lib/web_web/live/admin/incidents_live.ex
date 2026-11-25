defmodule MysticWeb.Admin.IncidentsLive do
  @moduledoc "Incidents and their timeline; resolving one requires a summary."
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard

  on_mount {Guard, :staff}

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         page_title: gettext("Incidents"),
         new_form: to_form(%{"title" => "", "body" => ""}, as: :incident),
         update_form: to_form(%{"body" => "", "summary" => ""}, as: :update),
         next_status: "investigating"
       )}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Api.get(socket, :accounts, "/api/admin/incidents/:id", path_params: [id: id]) do
      {:ok, %{"incident" => incident}} ->
        {:noreply,
         assign(socket,
           incident: incident,
           next_status: incident["status"],
           page_title: incident["title"]
         )}

      {:error, {:http, 404, _}} ->
        raise MysticWeb.NotFoundError

      _ ->
        {:noreply, assign(socket, incident: :unavailable)}
    end
  end

  def handle_params(params, _uri, socket) do
    case Api.get(socket, :accounts, "/api/admin/incidents", params: [page: params["page"] || "1"]) do
      {:ok, %{"entries" => _} = page} -> {:noreply, assign(socket, page: page)}
      _ -> {:noreply, assign(socket, page: :unavailable)}
    end
  end

  @impl true
  def handle_event("open", %{"incident" => params}, socket) do
    case Api.post(socket, :accounts, "/api/admin/incidents", json: params) do
      {:ok, %{"incident" => %{"id" => id}}} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Incident opened."))
         |> push_navigate(to: ~p"/admin/incidents/#{id}")}

      error ->
        errors = Api.form_errors(error, [:title, :severity, :body])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        {:noreply, assign(socket, new_form: to_form(params, as: :incident, errors: errors))}
    end
  end

  def handle_event("update_change", %{"update" => params}, socket),
    do: {:noreply, assign(socket, next_status: params["status"] || socket.assigns.next_status)}

  def handle_event("update", %{"update" => params}, socket) do
    case Api.post(socket, :accounts, "/api/admin/incidents/:id/updates",
           path_params: [id: socket.assigns.incident["id"]],
           json: params
         ) do
      {:ok, %{"incident" => incident}} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Timeline updated."))
         |> assign(
           incident: incident,
           next_status: incident["status"],
           update_form: to_form(%{"body" => "", "summary" => ""}, as: :update)
         )}

      error ->
        errors = Api.form_errors(error, [:body, :summary, :status, :severity])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        {:noreply, assign(socket, update_form: to_form(params, as: :update, errors: errors))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp severity_options,
    do: for(s <- ~w(low medium high critical), do: {severity_label(s), s})

  defp status_options,
    do: for(s <- ~w(open investigating resolved), do: {incident_status_label(s), s})

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:incidents}
    >
      <div class="space-y-6">
        <.page_header eyebrow={gettext("Operations")} title={gettext("Incidents")}>
          {gettext("Track outages and abuse waves with a timeline. Resolving one requires a summary.")}
        </.page_header>
        <%= case @page do %>
          <% :unavailable -> %>
            <.unavailable id="incidents-unavailable">
              {gettext("Incidents can't be loaded right now.")}
            </.unavailable>
          <% %{"entries" => []} -> %>
            <.empty_state
              id="incidents-empty"
              icon="hero-check-circle"
              title={gettext("No incident")}
            />
          <% page -> %>
            <table class="admin-table" id="incidents">
              <thead>
                <tr>
                  <th scope="col">{gettext("Incident")}</th>
                  <th scope="col">{gettext("Severity")}</th>
                  <th scope="col">{gettext("Status")}</th>
                  <th scope="col">{gettext("Opened")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={i <- page["entries"]} id={"incident-#{i["id"]}"}>
                  <td data-label={gettext("Incident")}>
                    <.link navigate={~p"/admin/incidents/#{i["id"]}"} class="link">{i["title"]}</.link>
                  </td>
                  <td data-label={gettext("Severity")}><.severity_tag severity={i["severity"]} /></td>
                  <td data-label={gettext("Status")}>{incident_status_label(i["status"])}</td>
                  <td data-label={gettext("Opened")} class="nowrap">
                    {message_time(i["inserted_at"])}
                  </td>
                </tr>
              </tbody>
            </table>
            <.pager page={page} path={&~p"/admin/incidents?#{%{page: &1}}"} />
        <% end %>

        <section class="card space-y-4" aria-labelledby="new-incident-title" id="new-incident">
          <h2 id="new-incident-title" class="text-2xl">{gettext("Open an incident")}</h2>
          <.form for={@new_form} id="incident-form" phx-submit="open" class="space-y-4">
            <.input field={@new_form[:title]} label={gettext("Title")} required maxlength="140" />
            <.input
              name="incident[severity]"
              id="incident-severity"
              type="select"
              label={gettext("Severity")}
              value="medium"
              options={severity_options()}
            />
            <.input
              field={@new_form[:body]}
              type="textarea"
              rows="3"
              maxlength="2000"
              label={gettext("First update (optional)")}
            />
            <.button type="submit" id="open-incident">{gettext("Open")}</.button>
          </.form>
        </section>
      </div>
    </Layouts.admin>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:incidents}
    >
      <div class="space-y-6">
        <.link navigate={~p"/admin/incidents"} class="link text-sm">← {gettext("All incidents")}</.link>
        <%= case @incident do %>
          <% :unavailable -> %>
            <.unavailable id="incident-unavailable">
              {gettext("This incident can't be loaded right now.")}
            </.unavailable>
          <% i -> %>
            <.page_header eyebrow={incident_status_label(i["status"])} title={i["title"]}>
              {gettext("Opened %{date} by", date: message_time(i["inserted_at"]))}
              <.person person={i["created_by"]} />
            </.page_header>
            <div class="flex flex-wrap gap-2"><.severity_tag severity={i["severity"]} /></div>
            <.notice
              :if={i["status"] == "resolved"}
              kind="success"
              title={gettext("Resolved")}
              id="incident-summary"
            >
              {i["summary"]}
            </.notice>
            <section class="card space-y-4" aria-labelledby="timeline-title">
              <h2 id="timeline-title" class="text-2xl">{gettext("Timeline")}</h2>
              <p :if={i["updates"] == []} class="text-sm text-muted">{gettext("No update yet.")}</p>
              <ol class="timeline" id="timeline">
                <li :for={u <- i["updates"]} id={"update-#{u["id"]}"} class="space-y-1">
                  <p class="text-xs text-muted">
                    {message_time(u["inserted_at"])} · <.person person={u["author"]} />
                    <span :if={u["status"]}>· {incident_status_label(u["status"])}</span>
                  </p>
                  <p class="whitespace-pre-wrap text-sm">{u["body"]}</p>
                </li>
              </ol>
            </section>
            <section
              :if={i["status"] != "resolved"}
              class="card space-y-4"
              aria-labelledby="update-title"
              id="incident-update"
            >
              <h2 id="update-title" class="text-2xl">{gettext("Add an update")}</h2>
              <.form
                for={@update_form}
                id="update-form"
                phx-change="update_change"
                phx-submit="update"
                class="space-y-4"
              >
                <.input
                  field={@update_form[:body]}
                  type="textarea"
                  rows="3"
                  maxlength="2000"
                  label={gettext("Update")}
                  required
                />
                <div class="grid gap-4 sm:grid-cols-2">
                  <.input
                    name="update[status]"
                    id="update-status"
                    type="select"
                    label={gettext("Status")}
                    value={@next_status}
                    options={status_options()}
                  />
                  <.input
                    name="update[severity]"
                    id="update-severity"
                    type="select"
                    label={gettext("Severity")}
                    value={i["severity"]}
                    options={severity_options()}
                  />
                </div>
                <.input
                  :if={@next_status == "resolved"}
                  field={@update_form[:summary]}
                  type="textarea"
                  rows="3"
                  maxlength="2000"
                  label={gettext("Resolution summary (required to resolve)")}
                  required
                />
                <.button type="submit" id="save-update">{gettext("Save")}</.button>
              </.form>
            </section>
        <% end %>
      </div>
    </Layouts.admin>
    """
  end
end
