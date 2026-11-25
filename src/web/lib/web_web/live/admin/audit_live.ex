defmodule MysticWeb.Admin.AuditLive do
  @moduledoc "Central audit log for admins, with filters and CSV export."
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard

  on_mount {Guard, :admin}

  @filters ~w(action actor from to)

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Audit log"))}

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      for key <- @filters,
          value = params[key],
          value not in [nil, ""],
          into: %{},
          do: {key, value}

    query = Map.put(filters, "page", params["page"] || "1")

    case Api.get(socket, :accounts, "/api/admin/audit", params: Map.to_list(query)) do
      {:ok, %{"entries" => _} = page} ->
        {:noreply, assign(socket, filters: filters, page: page, error: nil)}

      {:error, {:http, 422, _}} ->
        {:noreply,
         assign(socket, filters: filters, page: nil, error: gettext("Use dates like 2026-11-23."))}

      _ ->
        {:noreply, assign(socket, filters: filters, page: :unavailable, error: nil)}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    query =
      for {k, v} <- Map.take(params, @filters),
          String.trim(v) != "",
          into: %{},
          do: {k, String.trim(v)}

    {:noreply, push_patch(socket, to: ~p"/admin/audit?#{query}")}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp metadata(map) when map == %{}, do: ""
  defp metadata(map), do: Enum.map_join(map, ", ", fn {k, v} -> "#{k}: #{inspect_value(v)}" end)

  defp inspect_value(v) when is_binary(v), do: v
  defp inspect_value(v), do: Jason.encode!(v)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:audit}
    >
      <div class="space-y-6">
        <.page_header eyebrow={gettext("Admins only")} title={gettext("Audit log")}>
          {gettext("Every staff action of every service, append-only. Exports are recorded too.")}
          <:actions>
            <.link
              href={~p"/admin/audit/export?#{@filters}"}
              class="btn btn-secondary"
              id="export-csv"
              download
            >
              <.icon name="hero-arrow-down-tray" /> {gettext("Export CSV")}
            </.link>
          </:actions>
        </.page_header>

        <.form for={%{}} as={:filters} id="audit-filters" phx-submit="filter" class="card">
          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              name="filters[action]"
              id="filter-action"
              value={@filters["action"]}
              label={gettext("Action starts with")}
              placeholder="social.report"
            />
            <.input
              name="filters[actor]"
              id="filter-actor"
              value={@filters["actor"]}
              label={gettext("Actor (username)")}
            />
            <.input
              name="filters[from]"
              id="filter-from"
              type="date"
              value={@filters["from"]}
              label={gettext("From")}
            />
            <.input
              name="filters[to]"
              id="filter-to"
              type="date"
              value={@filters["to"]}
              label={gettext("To")}
            />
          </div>
          <div class="pt-4">
            <.button type="submit" variant="secondary" id="apply-filters">{gettext("Filter")}</.button>
          </div>
        </.form>
        <p class="text-sm text-muted">
          {gettext("The CSV export holds at most 10,000 entries (the most recent ones).")}
        </p>

        <.notice :if={@error} kind="warning" id="audit-error">{@error}</.notice>
        <%= case @page do %>
          <% nil -> %>
          <% :unavailable -> %>
            <.unavailable id="audit-unavailable">
              {gettext("The audit log can't be loaded right now.")}
            </.unavailable>
          <% %{"entries" => []} -> %>
            <.empty_state id="audit-empty" icon="hero-document-text" title={gettext("No entry")} />
          <% page -> %>
            <table class="admin-table" id="audit">
              <thead>
                <tr>
                  <th scope="col">{gettext("When")}</th>
                  <th scope="col">{gettext("Actor")}</th>
                  <th scope="col">{gettext("Action")}</th>
                  <th scope="col">{gettext("Target")}</th>
                  <th scope="col">{gettext("Reason")}</th>
                  <th scope="col">{gettext("Details")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={e <- page["entries"]} id={"audit-#{e["id"]}"}>
                  <td data-label={gettext("When")} class="nowrap">
                    {message_time(e["inserted_at"])}
                  </td>
                  <td data-label={gettext("Actor")}><.person person={e["actor"]} /></td>
                  <td data-label={gettext("Action")}><code class="text-sm">{e["action"]}</code></td>
                  <td data-label={gettext("Target")}>
                    <code class="text-sm">{e["target_type"]}</code> {e["target_id"]}
                  </td>
                  <td data-label={gettext("Reason")}>{e["reason"]}</td>
                  <td data-label={gettext("Details")} class="text-sm text-muted">
                    {metadata(e["metadata"])}
                  </td>
                </tr>
              </tbody>
            </table>
            <.pager page={page} path={&~p"/admin/audit?#{Map.put(@filters, "page", &1)}"} />
        <% end %>
      </div>
    </Layouts.admin>
    """
  end
end
