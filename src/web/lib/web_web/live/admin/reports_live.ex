defmodule MysticWeb.Admin.ReportsLive do
  @moduledoc """
  Report queue for the staff. A reported private message is only shown after the staff member gives a reason.
  """
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard

  on_mount {Guard, :staff}

  @durations [1, 24, 72, 168, 720]

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket, page_title: gettext("Reports"), evidence: nil, resolve_action: "dismiss")}

  @impl true
  def handle_params(
        %{"source" => source, "id" => id},
        _uri,
        %{assigns: %{live_action: :show}} = socket
      )
      when source in ~w(social community) do
    {:noreply,
     socket
     |> assign(source: source, id: id, evidence: nil, resolve_action: "dismiss")
     |> assign(evidence_form: to_form(%{"reason" => ""}, as: :evidence))
     |> assign(resolve_form: to_form(%{"reason" => ""}, as: :resolve))
     |> load_report()}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :show}}),
    do: raise(MysticWeb.NotFoundError)

  def handle_params(params, _uri, socket) do
    filters = %{
      "source" => pick(params["source"], ~w(all messages forum)),
      "status" => pick(params["status"], ~w(open resolved)),
      "reason" => pick(params["reason"], ~w(all harassment spam inappropriate other)),
      "page" => page(params["page"])
    }

    {:noreply, socket |> assign(filters: filters) |> load_queue()}
  end

  defp pick(value, [default | _] = allowed), do: if(value in allowed, do: value, else: default)

  defp page(value) do
    case Integer.parse(to_string(value || "1")) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  ## Queue

  defp load_queue(socket) do
    f = socket.assigns.filters
    params = [status: f["status"], page: f["page"]]

    social =
      if f["source"] in ~w(all messages),
        do: fetch_page(socket, :social, params),
        else: :skipped

    # the forum service lists open reports only
    community =
      if f["source"] in ~w(all forum) and f["status"] == "open",
        do: fetch_page(socket, :community, page: f["page"]),
        else: :skipped

    entries =
      [{"social", social}, {"community", community}]
      |> Enum.flat_map(fn
        {source, %{"entries" => entries}} -> Enum.map(entries, &normalize(source, &1))
        _ -> []
      end)
      |> Enum.filter(&(f["reason"] == "all" or &1.reason == f["reason"]))
      |> Enum.sort_by(& &1.inserted_at, if(f["status"] == "open", do: :asc, else: :desc))

    more? =
      Enum.any?([social, community], &(is_map(&1) and &1["page"] < &1["total_pages"]))

    assign(socket, entries: entries, social: social, community: community, more?: more?)
  end

  defp fetch_page(socket, service, params) do
    case Api.get(socket, service, "/api/moderation/reports", params: params) do
      {:ok, %{"entries" => _} = page} -> page
      _ -> :unavailable
    end
  end

  defp normalize("social", r) do
    %{
      source: "social",
      id: r["id"],
      kind:
        cond do
          r["target_type"] == "message" -> :message
          r["context"] == "multiplayer" -> :player
          true -> :member
        end,
      reason: r["reason"],
      details: r["details"],
      reporter: r["reporter"],
      reported: r["reported_user"],
      status: r["status"],
      inserted_at: r["inserted_at"]
    }
  end

  defp normalize("community", r) do
    %{
      source: "community",
      id: r["id"],
      kind: if(r["target_type"] == "discussion", do: :discussion, else: :reply),
      reason: r["reason"],
      details: r["details"],
      reporter: r["reporter"],
      reported: get_in(r, ["snapshot", "author"]),
      status: r["status"],
      inserted_at: r["inserted_at"]
    }
  end

  defp report_kind(:message), do: gettext("Private message")
  defp report_kind(:member), do: gettext("Member")
  defp report_kind(:player), do: gettext("Player (multiplayer lobby)")
  defp report_kind(:discussion), do: gettext("Forum discussion")
  defp report_kind(:reply), do: gettext("Forum reply")

  ## Case file

  defp load_report(socket) do
    case Api.get(socket, service(socket), "/api/moderation/reports/:id",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"report" => report}} -> assign(socket, report: report)
      {:error, {:http, 404, _}} -> raise MysticWeb.NotFoundError
      _ -> assign(socket, report: :unavailable)
    end
  end

  defp service(%{assigns: %{source: "social"}}), do: :social
  defp service(_socket), do: :community

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    query = params |> Map.take(~w(source status reason)) |> Map.put("page", 1)
    {:noreply, push_patch(socket, to: ~p"/admin/reports?#{query}")}
  end

  def handle_event("evidence", %{"evidence" => %{"reason" => reason}}, socket) do
    reason = String.trim(reason)

    if String.length(reason) < 10 do
      message = gettext("Give a reason of at least 10 characters to view the evidence.")
      form = to_form(%{"reason" => reason}, as: :evidence, errors: [reason: {message, []}])
      {:noreply, assign(socket, evidence_form: form)}
    else
      case Api.post(socket, :social, "/api/moderation/reports/:id/evidence",
             path_params: [id: socket.assigns.id],
             json: %{reason: reason}
           ) do
        {:ok, %{"evidence" => evidence}} ->
          {:noreply, assign(socket, evidence: evidence)}

        error ->
          {:noreply, put_flash(socket, :error, Api.error_message(error))}
      end
    end
  end

  def handle_event("resolve_change", %{"resolve" => %{"action" => action}}, socket),
    do: {:noreply, assign(socket, resolve_action: action)}

  def handle_event("resolve", %{"resolve" => params}, socket) do
    body =
      params
      |> Map.take(~w(action reason))
      |> then(fn body ->
        if params["action"] == "restrict",
          do: Map.put(body, "duration_hours", hours(params["duration_hours"])),
          else: body
      end)

    case Api.post(socket, service(socket), "/api/moderation/reports/:id/resolve",
           path_params: [id: socket.assigns.id],
           json: body
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Report resolved."))
         |> push_navigate(to: ~p"/admin/reports")}

      error ->
        errors = Api.form_errors(error, [:reason, :action, :duration_hours])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        form = to_form(params, as: :resolve, errors: errors, action: :validate)
        {:noreply, assign(socket, resolve_form: form)}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # social checks the bounds (1..720); anything that isn't a number is sent as is and refused there
  defp hours(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> value
    end
  end

  defp duration_options do
    [
      {gettext("1 hour"), 1},
      {gettext("24 hours"), 24},
      {gettext("3 days"), 72},
      {gettext("7 days"), 168},
      {gettext("30 days"), 720}
    ]
    |> Enum.filter(fn {_, h} -> h in @durations end)
  end

  defp social_actions(report) do
    [{gettext("Dismiss (no action)"), "dismiss"}] ++
      if(report["target_type"] == "message",
        do: [{gettext("Remove the message"), "remove_message"}],
        else: []
      ) ++
      [
        {gettext("Warn the member"), "warn"},
        {gettext("Restrict the member"), "restrict"}
      ]
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:reports}
    >
      <div class="space-y-6">
        <.page_header eyebrow={gettext("Moderation")} title={gettext("Reports")}>
          {gettext(
            "Reports about private messages, members, players and forum posts. Private messages are never shown in this list."
          )}
        </.page_header>

        <.form for={%{}} as={:filters} id="report-filters" phx-change="filter" class="card">
          <div class="grid gap-4 sm:grid-cols-3">
            <.input
              name="filters[source]"
              id="filter-source"
              type="select"
              label={gettext("Source")}
              value={@filters["source"]}
              options={[
                {gettext("All sources"), "all"},
                {gettext("Messages and members"), "messages"},
                {gettext("Forum"), "forum"}
              ]}
            />
            <.input
              name="filters[status]"
              id="filter-status"
              type="select"
              label={gettext("Status")}
              value={@filters["status"]}
              options={[{gettext("Open"), "open"}, {gettext("Resolved"), "resolved"}]}
            />
            <.input
              name="filters[reason]"
              id="filter-reason"
              type="select"
              label={gettext("Reason")}
              value={@filters["reason"]}
              options={[
                {gettext("All reasons"), "all"},
                {reason_label("harassment"), "harassment"},
                {reason_label("spam"), "spam"},
                {reason_label("inappropriate"), "inappropriate"},
                {reason_label("other"), "other"}
              ]}
            />
          </div>
        </.form>

        <.unavailable :if={@social == :unavailable} id="social-unavailable">
          {gettext("Message and member reports can't be loaded right now.")}
        </.unavailable>
        <.unavailable :if={@community == :unavailable} id="community-unavailable">
          {gettext("Forum reports can't be loaded right now.")}
        </.unavailable>
        <p
          :if={@filters["status"] == "resolved" and @filters["source"] != "messages"}
          class="text-sm text-muted"
        >
          {gettext("The forum lists open reports only; resolved forum reports stay in the audit log.")}
        </p>

        <.empty_state
          :if={@entries == []}
          id="reports-empty"
          icon="hero-check-badge"
          title={gettext("No report here")}
        />

        <table :if={@entries != []} class="admin-table" id="reports">
          <thead>
            <tr>
              <th scope="col">{gettext("Reported")}</th>
              <th scope="col">{gettext("Type")}</th>
              <th scope="col">{gettext("Reason")}</th>
              <th scope="col">{gettext("Reporter")}</th>
              <th scope="col">{gettext("Date")}</th>
              <th scope="col"><span class="sr-only">{gettext("Case file")}</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @entries} id={"report-#{r.source}-#{r.id}"}>
              <td data-label={gettext("Reported")}><.person person={r.reported} /></td>
              <td data-label={gettext("Type")}>{report_kind(r.kind)}</td>
              <td data-label={gettext("Reason")}>{reason_label(r.reason)}</td>
              <td data-label={gettext("Reporter")}><.person person={r.reporter} /></td>
              <td data-label={gettext("Date")} class="nowrap">{message_time(r.inserted_at)}</td>
              <td data-label={gettext("Case file")}>
                <.link navigate={~p"/admin/reports/#{r.source}/#{r.id}"} class="link">
                  {gettext("Open")}
                </.link>
              </td>
            </tr>
          </tbody>
        </table>

        <nav
          :if={@filters["page"] > 1 or @more?}
          class="flex justify-between gap-3"
          aria-label={gettext("Pagination")}
        >
          <.link
            :if={@filters["page"] > 1}
            patch={~p"/admin/reports?#{Map.put(@filters, "page", @filters["page"] - 1)}"}
            class="btn btn-secondary"
          >
            ← {gettext("Previous")}
          </.link>
          <.link
            :if={@more?}
            patch={~p"/admin/reports?#{Map.put(@filters, "page", @filters["page"] + 1)}"}
            class="btn btn-secondary"
          >
            {gettext("Next")} →
          </.link>
        </nav>
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
      active={:reports}
    >
      <div class="space-y-6">
        <.link navigate={~p"/admin/reports"} class="link text-sm">← {gettext("All reports")}</.link>
        <%= case @report do %>
          <% :unavailable -> %>
            <.unavailable id="report-unavailable">
              {gettext("This report can't be loaded right now.")}
            </.unavailable>
          <% report -> %>
            <.page_header
              eyebrow={gettext("Case file")}
              title={reason_label(report["reason"])}
            >
              {gettext("Reported %{date} by", date: message_time(report["inserted_at"]))}
              <.person person={report["reporter"]} />
            </.page_header>

            <section class="card space-y-3" aria-labelledby="report-facts" id="report-facts-card">
              <h2 id="report-facts" class="text-2xl">{gettext("Facts")}</h2>
              <dl class="grid gap-3 sm:grid-cols-2">
                <div>
                  <dt class="text-sm text-muted">{gettext("Reported member")}</dt>
                  <dd>
                    <.person person={
                      report["reported_user"] || get_in(report, ["snapshot", "author"])
                    } />
                    <.link
                      :if={
                        (report["reported_user"] || get_in(report, ["snapshot", "author"]) || %{})[
                          "id"
                        ]
                      }
                      navigate={
                        ~p"/admin/members/#{(report["reported_user"] || get_in(report, ["snapshot", "author"]))["id"]}"
                      }
                      class="link text-sm"
                    >
                      {gettext("Member file")}
                    </.link>
                  </dd>
                </div>
                <div>
                  <dt class="text-sm text-muted">{gettext("Status")}</dt>
                  <dd id="report-status">
                    {if report["status"] == "open", do: gettext("Open"), else: gettext("Resolved")}
                  </dd>
                </div>
                <div :if={report["details"]} class="sm:col-span-2">
                  <dt class="text-sm text-muted">{gettext("Reporter's details")}</dt>
                  <dd class="whitespace-pre-wrap">{report["details"]}</dd>
                </div>
                <div :if={report["resolution"]} class="sm:col-span-2">
                  <dt class="text-sm text-muted">{gettext("Resolution")}</dt>
                  <dd>{report["resolution"]["action"]} — {report["resolution"]["reason"]}</dd>
                </div>
              </dl>
            </section>

            <section
              :if={@source == "social" and report["target_type"] == "message"}
              class="card space-y-4"
              aria-labelledby="evidence-title"
              id="evidence-card"
            >
              <h2 id="evidence-title" class="text-2xl">{gettext("Reported message")}</h2>
              <p class="text-sm text-muted">
                {gettext(
                  "Private messages are confidential. Only the reported message can be shown, after you state why; your reason is written to the audit log first."
                )}
              </p>
              <p :if={get_in(report, ["message", "removed"])} class="text-sm">
                <.icon name="hero-eye-slash" class="size-4" /> {gettext(
                  "This message has been removed by moderation."
                )}
              </p>
              <%= if @evidence do %>
                <div :if={@evidence["body"]} class="evidence" id="evidence">{@evidence["body"]}</div>
                <p class="text-sm text-muted">
                  {gettext("Sent %{date} by", date: message_time(@evidence["sent_at"]))}
                  <.person person={@evidence["sender"]} />
                </p>
                <div
                  :if={attachment = @evidence["attachment"]}
                  id="evidence-attachment"
                  class="space-y-3 border-t border-line pt-4"
                >
                  <p class="text-sm">
                    <.icon name="hero-paper-clip" class="size-4" />
                    {gettext("Attachment: %{name} (%{kind}, %{size})",
                      name: attachment["filename"] || gettext("deleted"),
                      kind: attachment["kind"],
                      size: MysticWeb.MessagesComponents.file_size(attachment["byte_size"])
                    )}
                  </p>
                  <.form
                    :if={attachment["available"]}
                    for={%{}}
                    as={:attachment}
                    id="attachment-evidence-form"
                    action={~p"/admin/reports/social/#{report["id"]}/attachment"}
                    method="post"
                    class="space-y-3"
                  >
                    <.input
                      id="attachment-evidence-reason"
                      name="attachment[reason]"
                      value=""
                      type="textarea"
                      rows="2"
                      maxlength="1000"
                      label={
                        gettext("Why do you need to open the attachment? (at least 10 characters)")
                      }
                    />
                    <.button type="submit" variant="secondary" id="open-attachment">
                      <.icon name="hero-arrow-down-tray" /> {gettext("Download the attachment")}
                    </.button>
                  </.form>
                </div>
              <% else %>
                <.form for={@evidence_form} id="evidence-form" phx-submit="evidence" class="space-y-3">
                  <.input
                    field={@evidence_form[:reason]}
                    type="textarea"
                    rows="2"
                    maxlength="1000"
                    label={gettext("Why do you need to read this message? (at least 10 characters)")}
                  />
                  <.button type="submit" variant="secondary" id="view-evidence">
                    <.icon name="hero-eye" /> {gettext("View the reported message")}
                  </.button>
                </.form>
              <% end %>
            </section>

            <section
              :if={@source == "community" and report["snapshot"]}
              class="card space-y-3"
              aria-labelledby="snapshot-title"
              id="snapshot-card"
            >
              <h2 id="snapshot-title" class="text-2xl">{gettext("Reported forum post")}</h2>
              <p class="font-medium text-ink">{report["snapshot"]["title"]}</p>
              <div class="evidence">{report["snapshot"]["body"]}</div>
              <.link
                navigate={~p"/community/discussions/#{report["snapshot"]["discussion_slug"]}"}
                class="link text-sm"
              >
                {gettext("Open the discussion")}
              </.link>
            </section>

            <section
              :if={report["status"] == "open"}
              class="card space-y-4"
              aria-labelledby="decision-title"
              id="decision"
            >
              <h2 id="decision-title" class="text-2xl">{gettext("Decision")}</h2>
              <.form
                for={@resolve_form}
                id="resolve-form"
                phx-change="resolve_change"
                phx-submit="resolve"
                class="space-y-4"
              >
                <.input
                  name="resolve[action]"
                  id="resolve-action"
                  type="select"
                  label={gettext("Action")}
                  value={@resolve_action}
                  options={
                    if @source == "social",
                      do: social_actions(report),
                      else: [
                        {gettext("Dismiss (no action)"), "dismiss"},
                        {gettext("Hide the post"), "hide"},
                        {gettext("Remove the post"), "remove"}
                      ]
                  }
                />
                <.input
                  :if={@resolve_action == "restrict"}
                  name="resolve[duration_hours]"
                  id="resolve-duration"
                  type="select"
                  label={gettext("Restriction length")}
                  value="24"
                  options={duration_options()}
                />
                <.input
                  field={@resolve_form[:reason]}
                  type="textarea"
                  rows="3"
                  maxlength="1000"
                  label={gettext("Reason (required, recorded in the audit log)")}
                  required
                />
                <.button type="submit" id="resolve" phx-disable-with={gettext("Saving…")}>
                  {gettext("Apply decision")}
                </.button>
              </.form>
            </section>
        <% end %>
      </div>
    </Layouts.admin>
    """
  end
end
