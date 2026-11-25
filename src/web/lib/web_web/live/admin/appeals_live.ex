defmodule MysticWeb.Admin.AppealsLive do
  @moduledoc """
  Appeals of sanctioned members, decided by a staff member other than the author of the sanction.
  """
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard

  on_mount {Guard, :staff}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Sanctions & appeals"))}

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] == "decided", do: "decided", else: "open"
    {:noreply, socket |> assign(status: status, page_number: params["page"] || "1") |> load()}
  end

  defp load(socket) do
    case Api.get(socket, :accounts, "/api/admin/appeals",
           params: [status: socket.assigns.status, page: socket.assigns.page_number]
         ) do
      {:ok, %{"entries" => _} = page} -> assign(socket, page: page)
      _ -> assign(socket, page: :unavailable)
    end
  end

  @impl true
  def handle_event("decide", %{"appeal_id" => id} = params, socket) do
    case Api.post(socket, :accounts, "/api/admin/appeals/:id/decide",
           path_params: [id: id],
           json: Map.take(params, ~w(decision reason))
         ) do
      {:ok, %{"appeal" => %{"status" => "accepted"}}} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Appeal accepted: the sanction is lifted.")) |> load()}

      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Appeal rejected.")) |> load()}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp own_sanction?(appeal, user),
    do: get_in(appeal, ["sanction", "issued_by", "id"]) == user["id"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:appeals}
    >
      <div class="space-y-6">
        <.page_header eyebrow={gettext("Moderation")} title={gettext("Sanctions & appeals")}>
          {gettext(
            "Members can appeal a sanction once at a time. Another staff member than the one who issued it decides."
          )}
        </.page_header>
        <nav class="flex gap-2" aria-label={gettext("Appeal lists")}>
          <.link
            patch={~p"/admin/sanctions-appeals"}
            class="nav-pill"
            aria-current={@status == "open" && "page"}
          >
            {gettext("Open")}
          </.link>
          <.link
            patch={~p"/admin/sanctions-appeals?status=decided"}
            class="nav-pill"
            aria-current={@status == "decided" && "page"}
          >
            {gettext("Decided")}
          </.link>
        </nav>

        <%= case @page do %>
          <% :unavailable -> %>
            <.unavailable id="appeals-unavailable">
              {gettext("Appeals can't be loaded right now.")}
            </.unavailable>
          <% %{"entries" => []} -> %>
            <.empty_state id="appeals-empty" icon="hero-scale" title={gettext("No appeal here")} />
          <% page -> %>
            <ul class="space-y-4" id="appeals">
              <li :for={a <- page["entries"]} id={"appeal-#{a["id"]}"} class="card space-y-3">
                <p class="flex flex-wrap items-center gap-2">
                  <.link navigate={~p"/admin/members/#{a["member"]["id"]}"} class="link">
                    {a["member"]["display_name"]}
                  </.link>
                  <span class="text-sm text-muted">@{a["member"]["username"]}</span>
                  <span class="font-medium text-ink">· {sanction_kind(a["sanction"]["kind"])}</span>
                  <.sanction_status status={a["sanction"]["status"]} />
                </p>
                <div class="grid gap-3 md:grid-cols-2">
                  <div class="space-y-1">
                    <p class="text-sm text-muted">
                      {gettext("Sanction issued %{date} by",
                        date: message_time(a["sanction"]["inserted_at"])
                      )}
                      <.person person={a["sanction"]["issued_by"]} />
                    </p>
                    <p class="whitespace-pre-wrap text-sm">{a["sanction"]["reason"]}</p>
                  </div>
                  <div class="space-y-1">
                    <p class="text-sm text-muted">
                      {gettext("Appeal sent %{date}", date: message_time(a["inserted_at"]))}
                    </p>
                    <p class="whitespace-pre-wrap text-sm">{a["body"]}</p>
                  </div>
                </div>
                <p :if={a["status"] != "open"} class="text-sm">
                  {if a["status"] == "accepted", do: gettext("Accepted"), else: gettext("Rejected")} — {a[
                    "decision_reason"
                  ]}
                  <span class="text-muted">(<.person person={a["decided_by"]} />)</span>
                </p>
                <%= if a["status"] == "open" do %>
                  <.notice :if={own_sanction?(a, @current_user)} kind="info" id={"own-#{a["id"]}"}>
                    {gettext(
                      "You issued this sanction: another staff member has to decide this appeal."
                    )}
                  </.notice>
                  <.form
                    :if={!own_sanction?(a, @current_user)}
                    for={%{}}
                    id={"decide-#{a["id"]}"}
                    phx-submit="decide"
                    class="space-y-3"
                  >
                    <input type="hidden" name="appeal_id" value={a["id"]} />
                    <.input
                      name="decision"
                      id={"decision-#{a["id"]}"}
                      type="select"
                      label={gettext("Decision")}
                      value="accept"
                      options={[
                        {gettext("Accept (lift the sanction)"), "accept"},
                        {gettext("Reject (keep the sanction)"), "reject"}
                      ]}
                    />
                    <.input
                      name="reason"
                      id={"decision-reason-#{a["id"]}"}
                      value=""
                      type="textarea"
                      rows="2"
                      maxlength="1000"
                      label={gettext("Reason (sent to the member)")}
                      required
                    />
                    <.button type="submit" id={"decide-submit-#{a["id"]}"}>{gettext("Decide")}</.button>
                  </.form>
                <% end %>
              </li>
            </ul>
            <.pager page={page} path={&~p"/admin/sanctions-appeals?#{%{status: @status, page: &1}}"} />
        <% end %>
      </div>
    </Layouts.admin>
    """
  end
end
