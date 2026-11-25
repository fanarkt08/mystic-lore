defmodule MysticWeb.Admin.MembersLive do
  @moduledoc "Members for the staff: search, member file, sanctions, avatar reset and roles."
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard

  on_mount {Guard, :staff}

  @doc "Events that need the admin role (checked by `MysticWeb.Admin.Guard` before any call)."
  def admin_events, do: ~w(set_role)

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: gettext("Members"))}

  @impl true
  # Loaded once connected only: an admin's viewing of full emails is audited by accounts, so the static
  # render must not count as a second viewing.
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(id: id, kind: "warning", member: :loading)
     |> assign(sanction_form: to_form(%{"reason" => ""}, as: :sanction))
     |> assign(role_form: to_form(%{"reason" => ""}, as: :role))
     |> assign(avatar_form: to_form(%{"reason" => ""}, as: :avatar_reset))
     |> then(&if(connected?(&1), do: load_member(&1), else: &1))}
  end

  def handle_params(params, _uri, socket) do
    query = %{"q" => String.trim(params["q"] || ""), "page" => params["page"] || "1"}

    cond do
      not connected?(socket) ->
        {:noreply, assign(socket, query: query, page: :loading)}

      true ->
        case Api.get(socket, :accounts, "/api/admin/users", params: Map.to_list(query)) do
          {:ok, %{"entries" => _} = page} -> {:noreply, assign(socket, query: query, page: page)}
          _ -> {:noreply, assign(socket, query: query, page: :unavailable)}
        end
    end
  end

  defp load_member(socket) do
    case Api.get(socket, :accounts, "/api/admin/users/:id", path_params: [id: socket.assigns.id]) do
      {:ok, %{"user" => user}} -> assign(socket, member: user, page_title: user["display_name"])
      {:error, {:http, 404, _}} -> assign(socket, member: :not_found)
      _ -> assign(socket, member: :unavailable)
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/admin/members?#{%{q: String.trim(q)}}")}

  def handle_event("sanction_change", %{"sanction" => %{"kind" => kind}}, socket),
    do: {:noreply, assign(socket, kind: kind)}

  def handle_event("sanction", %{"sanction" => params}, socket) do
    body =
      if params["kind"] == "restriction",
        do: Map.take(params, ~w(kind reason duration_hours)),
        else: Map.take(params, ~w(kind reason))

    case Api.post(socket, :accounts, "/api/admin/users/:id/sanctions",
           path_params: [id: socket.assigns.id],
           json: body
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Sanction recorded. The member has been notified."))
         |> assign(sanction_form: to_form(%{"reason" => ""}, as: :sanction))
         |> load_member()}

      error ->
        errors = Api.form_errors(error, [:reason, :duration_hours, :kind])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        {:noreply, assign(socket, sanction_form: to_form(params, as: :sanction, errors: errors))}
    end
  end

  def handle_event("lift", %{"sanction_id" => id, "reason" => reason}, socket) do
    case Api.post(socket, :accounts, "/api/admin/sanctions/:id/lift",
           path_params: [id: id],
           json: %{reason: reason}
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Sanction lifted.")) |> load_member()}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("reset_avatar", %{"avatar_reset" => params}, socket) do
    case Api.post(socket, :accounts, "/api/admin/users/:id/avatar/reset",
           path_params: [id: socket.assigns.id],
           json: Map.take(params, ~w(reason))
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Avatar reset: the member's initials are shown instead."))
         |> assign(avatar_form: to_form(%{"reason" => ""}, as: :avatar_reset))
         |> load_member()}

      error ->
        errors = Api.form_errors(error, [:reason])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        {:noreply,
         assign(socket, avatar_form: to_form(params, as: :avatar_reset, errors: errors))}
    end
  end

  def handle_event("set_role", %{"role" => params}, socket) do
    case Api.put(socket, :accounts, "/api/admin/users/:id/role",
           path_params: [id: socket.assigns.id],
           json: Map.take(params, ~w(role reason))
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role updated."))
         |> assign(role_form: to_form(%{"reason" => ""}, as: :role))
         |> load_member()}

      error ->
        errors = Api.form_errors(error, [:reason, :role])

        socket =
          if errors == [], do: put_flash(socket, :error, Api.error_message(error)), else: socket

        {:noreply, assign(socket, role_form: to_form(params, as: :role, errors: errors))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp state(member) do
    cond do
      member["deletion_scheduled_at"] ->
        gettext("Deletion scheduled")

      member["restricted_until"] ->
        gettext("Restricted until %{date}", date: message_time(member["restricted_until"]))

      member["confirmed"] ->
        gettext("Active")

      true ->
        gettext("Email not confirmed")
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:members}
    >
      <div class="space-y-6">
        <.page_header eyebrow={gettext("Moderation")} title={gettext("Members")}>
          {if Guard.admin?(@current_user),
            do:
              gettext(
                "As an admin you see full email addresses: each viewing is recorded in the audit log."
              ),
            else: gettext("Email addresses are masked for moderators.")}
        </.page_header>
        <.form
          for={%{}}
          id="member-search"
          phx-submit="search"
          class="card flex flex-wrap items-end gap-3"
        >
          <div class="min-w-0 flex-1">
            <.input
              name="q"
              id="member-q"
              value={@query["q"]}
              label={gettext("Search by username or display name")}
              maxlength="100"
            />
          </div>
          <.button type="submit" variant="secondary">{gettext("Search")}</.button>
        </.form>

        <%= case @page do %>
          <% :loading -> %>
            <p class="text-muted">{gettext("Loading…")}</p>
          <% :unavailable -> %>
            <.unavailable id="members-unavailable">
              {gettext("Members can't be loaded right now.")}
            </.unavailable>
          <% %{"entries" => []} -> %>
            <.empty_state id="members-empty" icon="hero-users" title={gettext("No member found")} />
          <% page -> %>
            <table class="admin-table" id="members">
              <thead>
                <tr>
                  <th scope="col">{gettext("Member")}</th>
                  <th scope="col">{gettext("Email")}</th>
                  <th scope="col">{gettext("Role")}</th>
                  <th scope="col">{gettext("State")}</th>
                  <th scope="col">{gettext("Joined")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={m <- page["entries"]} id={"member-#{m["id"]}"}>
                  <td data-label={gettext("Member")}>
                    <div>
                      <.link navigate={~p"/admin/members/#{m["id"]}"} class="link">{m["display_name"]}</.link>
                      <span class="block text-sm text-muted">@{m["username"]}</span>
                    </div>
                  </td>
                  <td data-label={gettext("Email")}>{m["email"]}</td>
                  <td data-label={gettext("Role")}><.role_tag role={m["role"]} /></td>
                  <td data-label={gettext("State")}>{state(m)}</td>
                  <td data-label={gettext("Joined")}>{date(m["inserted_at"])}</td>
                </tr>
              </tbody>
            </table>
            <.pager page={page} path={&~p"/admin/members?#{%{q: @query["q"], page: &1}}"} />
        <% end %>
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
      active={:members}
    >
      <div class="space-y-6">
        <.link navigate={~p"/admin/members"} class="link text-sm">← {gettext("All members")}</.link>
        <%= case @member do %>
          <% :loading -> %>
            <p class="text-muted">{gettext("Loading…")}</p>
          <% :not_found -> %>
            <.notice id="member-not-found" kind="info">
              {gettext("This member doesn't exist or their account was deleted.")}
            </.notice>
          <% :unavailable -> %>
            <.unavailable id="member-unavailable">
              {gettext("This member can't be loaded right now.")}
            </.unavailable>
          <% m -> %>
            <.page_header eyebrow={"@" <> m["username"]} title={m["display_name"]}>
              {m["email"]}
            </.page_header>
            <section class="card" aria-labelledby="member-state-title" id="member-state">
              <h2 id="member-state-title" class="sr-only">{gettext("State")}</h2>
              <dl class="grid gap-4 sm:grid-cols-4">
                <div>
                  <dt class="text-sm text-muted">{gettext("Role")}</dt>
                  <dd><.role_tag role={m["role"]} /></dd>
                </div>
                <div>
                  <dt class="text-sm text-muted">{gettext("State")}</dt>
                  <dd id="member-state-value">{state(m)}</dd>
                </div>
                <div>
                  <dt class="text-sm text-muted">{gettext("Two-factor authentication")}</dt>
                  <dd>{if m["two_factor"], do: gettext("On"), else: gettext("Off")}</dd>
                </div>
                <div>
                  <dt class="text-sm text-muted">{gettext("Scheduled deletion")}</dt>
                  <dd>
                    {if m["deletion_scheduled_at"],
                      do: date(m["deletion_scheduled_at"]),
                      else: gettext("None")}
                  </dd>
                </div>
              </dl>
            </section>

            <section class="card space-y-4" aria-labelledby="sanctions-title" id="member-sanctions">
              <h2 id="sanctions-title" class="text-2xl">{gettext("Sanctions")}</h2>
              <p :if={m["sanctions"] == []} class="text-sm text-muted">{gettext("No sanction.")}</p>
              <ul class="space-y-3">
                <li
                  :for={s <- m["sanctions"]}
                  id={"sanction-#{s["id"]}"}
                  class="rounded-card border border-line p-4 space-y-2"
                >
                  <p class="flex flex-wrap items-center gap-2">
                    <span class="font-medium text-ink">{sanction_kind(s["kind"])}</span>
                    <.sanction_status status={s["status"]} />
                    <span :if={s["ends_at"]} class="text-sm text-muted">
                      {gettext("until %{date}", date: message_time(s["ends_at"]))}
                    </span>
                  </p>
                  <p class="whitespace-pre-wrap text-sm">{s["reason"]}</p>
                  <p class="text-xs text-muted">
                    {gettext("Issued %{date} by", date: message_time(s["inserted_at"]))}
                    <.person person={s["issued_by"]} />
                  </p>
                  <p :if={s["lift_reason"]} class="text-xs text-muted">
                    {gettext("Lifted: %{reason}", reason: s["lift_reason"])}
                  </p>
                  <.form
                    :if={s["status"] == "active"}
                    for={%{}}
                    id={"lift-#{s["id"]}"}
                    phx-submit="lift"
                    class="flex flex-wrap items-end gap-2"
                  >
                    <input type="hidden" name="sanction_id" value={s["id"]} />
                    <div class="min-w-0 flex-1">
                      <.input
                        name="reason"
                        id={"lift-reason-#{s["id"]}"}
                        value=""
                        label={gettext("Reason to lift it")}
                        required
                        maxlength="1000"
                      />
                    </div>
                    <.button type="submit" variant="secondary">{gettext("Lift")}</.button>
                  </.form>
                </li>
              </ul>
            </section>

            <section
              :if={m["avatar"]}
              class="card space-y-4"
              aria-labelledby="avatar-reset-title"
              id="avatar-reset"
            >
              <div class="flex flex-wrap items-center gap-4">
                <.avatar user={m} size="lg" />
                <div class="min-w-0 flex-1 space-y-1">
                  <h2 id="avatar-reset-title" class="text-2xl">{gettext("Avatar")}</h2>
                  <p class="text-sm text-muted">
                    {gettext(
                      "Resetting it shows the member's initials instead. The member can choose a new one."
                    )}
                  </p>
                </div>
              </div>
              <.form
                for={@avatar_form}
                id="avatar-reset-form"
                phx-submit="reset_avatar"
                class="space-y-4"
              >
                <.input
                  field={@avatar_form[:reason]}
                  label={gettext("Reason (recorded in the audit log, required)")}
                  required
                  minlength="5"
                  maxlength="500"
                />
                <.button type="submit" variant="danger" id="reset-avatar">
                  {gettext("Reset the avatar")}
                </.button>
              </.form>
            </section>

            <section
              :if={m["role"] == "user"}
              class="card space-y-4"
              aria-labelledby="new-sanction-title"
              id="new-sanction"
            >
              <h2 id="new-sanction-title" class="text-2xl">{gettext("Warn or restrict")}</h2>
              <p class="text-sm text-muted">
                {gettext(
                  "A restricted member can still read, learn and play, but can't send private messages, post in the forum or write in lobby chats. The member is notified and can appeal."
                )}
              </p>
              <.form
                for={@sanction_form}
                id="sanction-form"
                phx-change="sanction_change"
                phx-submit="sanction"
                class="space-y-4"
              >
                <.input
                  name="sanction[kind]"
                  id="sanction-kind"
                  type="select"
                  label={gettext("Sanction")}
                  value={@kind}
                  options={[
                    {gettext("Warning"), "warning"},
                    {gettext("Temporary restriction"), "restriction"}
                  ]}
                />
                <.input
                  :if={@kind == "restriction"}
                  name="sanction[duration_hours]"
                  id="sanction-duration"
                  type="select"
                  label={gettext("Duration")}
                  value="24"
                  options={[
                    {gettext("1 hour"), 1},
                    {gettext("24 hours"), 24},
                    {gettext("3 days"), 72},
                    {gettext("7 days"), 168},
                    {gettext("30 days"), 720}
                  ]}
                />
                <.input
                  field={@sanction_form[:reason]}
                  type="textarea"
                  rows="3"
                  maxlength="1000"
                  label={gettext("Reason (shown to the member, required)")}
                  required
                />
                <.button type="submit" variant="danger" id="issue-sanction">{gettext("Apply")}</.button>
              </.form>
            </section>

            <section
              :if={Guard.admin?(@current_user) and m["id"] != @current_user["id"]}
              class="card space-y-4"
              aria-labelledby="role-title"
              id="role-section"
            >
              <h2 id="role-title" class="text-2xl">{gettext("Role")}</h2>
              <.form for={@role_form} id="role-form" phx-submit="set_role" class="space-y-4">
                <.input
                  name="role[role]"
                  id="role-select"
                  type="select"
                  label={gettext("New role")}
                  value={m["role"]}
                  options={[
                    {gettext("Member"), "user"},
                    {gettext("Moderator"), "moderator"},
                    {gettext("Admin"), "admin"}
                  ]}
                />
                <.input
                  field={@role_form[:reason]}
                  label={gettext("Reason (recorded in the audit log)")}
                  required
                  maxlength="500"
                />
                <.button type="submit" variant="secondary" id="save-role">{gettext("Change role")}</.button>
              </.form>
            </section>
        <% end %>
      </div>
    </Layouts.admin>
    """
  end
end
