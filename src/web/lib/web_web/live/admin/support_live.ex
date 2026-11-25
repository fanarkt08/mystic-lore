defmodule MysticWeb.Admin.SupportLive do
  @moduledoc """
  Support requests for the staff, loaded once connected because accounts audits each viewing.
  """
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard
  alias MysticWeb.ContactLive

  on_mount {Guard, :staff}

  @doc "Events that need the admin role (checked by `MysticWeb.Admin.Guard` before any call)."
  def admin_events, do: ~w(delete)

  @statuses ~w(open answered closed)

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Support requests"))}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(id: id, request: :loading, reply_form: reply_form(), manage_form: nil)
     |> then(&if(connected?(&1), do: load_request(&1), else: &1))}
  end

  def handle_params(params, _uri, socket) do
    query = %{
      "status" => if(params["status"] in ["all" | @statuses], do: params["status"], else: "open"),
      "topic" => if(params["topic"] in ContactLive.topics(), do: params["topic"], else: ""),
      "q" => params["q"] |> to_string() |> String.trim() |> String.slice(0, 100),
      "page" => params["page"] || "1"
    }

    socket = assign(socket, query: query, page: :loading)

    if connected?(socket) do
      api_params =
        query
        |> Map.update!("status", &if(&1 == "all", do: nil, else: &1))
        |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

      case Api.get(socket, :accounts, "/api/admin/support/requests", params: api_params) do
        {:ok, %{"entries" => _} = page} -> {:noreply, assign(socket, page: page)}
        _ -> {:noreply, assign(socket, page: :unavailable)}
      end
    else
      {:noreply, socket}
    end
  end

  defp load_request(socket) do
    case Api.get(socket, :accounts, "/api/admin/support/requests/:id",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"request" => request}} -> put_request(socket, request)
      {:error, {:http, 404, _}} -> assign(socket, request: :not_found)
      _ -> assign(socket, request: :unavailable)
    end
  end

  defp put_request(socket, request) do
    assign(socket,
      request: request,
      page_title: request["reference"],
      manage_form:
        to_form(
          %{"status" => request["status"], "internal_note" => request["internal_note"] || ""},
          as: :manage
        )
    )
  end

  defp pager_path(query) do
    filters = Enum.reject(query, fn {_k, v} -> v in [nil, ""] end) |> Map.new()
    &~p"/admin/support?#{Map.put(filters, "page", &1)}"
  end

  defp reply_form(values \\ %{"body" => ""}, errors \\ []),
    do: to_form(values, as: :reply, errors: errors)

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    query =
      filter
      |> Map.take(~w(status topic q))
      |> Map.update("q", "", &String.trim/1)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    {:noreply, push_patch(socket, to: ~p"/admin/support?#{query}")}
  end

  def handle_event("reply", %{"reply" => %{"body" => body} = params}, socket) do
    case Api.post(socket, :accounts, "/api/admin/support/requests/:id/replies",
           path_params: [id: socket.assigns.id],
           json: %{body: body}
         ) do
      {:ok, %{"request" => request}} ->
        last = List.last(request["replies"] || [])

        socket =
          if last && last["email_status"] == "sent",
            do: put_flash(socket, :info, gettext("Reply sent by e-mail.")),
            else:
              put_flash(
                socket,
                :error,
                gettext("The reply is saved, but the e-mail could not be sent. Try again later.")
              )

        {:noreply, socket |> put_request(request) |> assign(reply_form: reply_form())}

      {:error, {:http, 422, _}} = error ->
        {:noreply,
         assign(socket, reply_form: reply_form(params, Api.form_errors(error, [:body])))}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("manage", %{"manage" => params}, socket) do
    case Api.patch(socket, :accounts, "/api/admin/support/requests/:id",
           path_params: [id: socket.assigns.id],
           json: Map.take(params, ~w(status internal_note))
         ) do
      {:ok, %{"request" => request}} ->
        {:noreply,
         socket |> put_request(request) |> put_flash(:info, gettext("Request updated."))}

      {:error, {:http, 422, _}} = error ->
        errors = Api.form_errors(error, [:status, :internal_note])
        {:noreply, assign(socket, manage_form: to_form(params, as: :manage, errors: errors))}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("delete", _params, socket) do
    case Api.delete(socket, :accounts, "/api/admin/support/requests/:id",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Request erased."))
         |> push_navigate(to: ~p"/admin/support")}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp status_label("open"), do: gettext("Open")
  defp status_label(status), do: ContactLive.status_label(status)

  attr :status, :string, required: true

  defp status_tag(assigns) do
    ~H"""
    <.tag kind={
      case @status do
        "open" -> "info"
        "answered" -> "success"
        _ -> "neutral"
      end
    }>
      {status_label(@status)}
    </.tag>
    """
  end

  attr :requester, :map, required: true

  defp requester(assigns) do
    ~H"""
    <span :if={@requester["kind"] == "member"} class="inline-flex flex-wrap gap-x-1">
      <.person person={@requester["member"]} />
      <span class="text-muted">· {gettext("member")}</span>
    </span>
    <span :if={@requester["kind"] == "visitor"}>{gettext("Visitor")}</span>
    <span :if={@requester["email"]} class="block break-all text-sm text-muted">
      {@requester["email"]}
    </span>
    """
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:support}
    >
      <div class="space-y-6">
        <.page_header eyebrow={gettext("Operations")} title={gettext("Support requests")}>
          {gettext(
            "Requests sent with the contact form. Opening one is recorded in the audit log; addresses are masked for moderators."
          )}
        </.page_header>

        <.form
          for={%{}}
          as={:filter}
          id="support-filters"
          phx-submit="filter"
          class="grid gap-4 md:grid-cols-[1fr_1fr_2fr_auto] md:items-end"
        >
          <.input
            type="select"
            id="filter-status"
            name="filter[status]"
            label={gettext("Status")}
            value={@query["status"]}
            options={[
              {gettext("All"), "all"} | for(s <- ~w(open answered closed), do: {status_label(s), s})
            ]}
          />
          <.input
            type="select"
            id="filter-topic"
            name="filter[topic]"
            label={gettext("Topic")}
            value={@query["topic"]}
            prompt={gettext("All topics")}
            options={for t <- ContactLive.topics(), do: {ContactLive.topic_label(t), t}}
          />
          <.input
            id="filter-q"
            name="filter[q]"
            value={@query["q"]}
            label={
              if MysticWeb.Admin.Guard.admin?(@current_user),
                do: gettext("Reference or e-mail address"),
                else: gettext("Reference")
            }
          />
          <.button type="submit" id="apply-filters">{gettext("Filter")}</.button>
        </.form>

        <%= case @page do %>
          <% :loading -> %>
            <p class="text-muted">{gettext("Loading…")}</p>
          <% :unavailable -> %>
            <.unavailable id="support-unavailable">
              {gettext("Support requests can't be loaded right now.")}
            </.unavailable>
          <% %{"entries" => []} -> %>
            <.empty_state id="support-empty" icon="hero-lifebuoy" title={gettext("No request here")}>
              {gettext("Nothing matches these filters.")}
            </.empty_state>
          <% page -> %>
            <table class="admin-table" id="support-requests">
              <thead>
                <tr>
                  <th scope="col">{gettext("Reference")}</th>
                  <th scope="col">{gettext("Topic")}</th>
                  <th scope="col">{gettext("From")}</th>
                  <th scope="col">{gettext("Status")}</th>
                  <th scope="col">{gettext("Received")}</th>
                  <th scope="col">{gettext("Replies")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- page["entries"]} id={"support-#{r["id"]}"}>
                  <td data-label={gettext("Reference")}>
                    <.link navigate={~p"/admin/support/#{r["id"]}"} class="link font-mono">
                      {r["reference"]}
                    </.link>
                  </td>
                  <td data-label={gettext("Topic")}>{ContactLive.topic_label(r["topic"])}</td>
                  <td data-label={gettext("From")}><.requester requester={r["requester"]} /></td>
                  <td data-label={gettext("Status")}><.status_tag status={r["status"]} /></td>
                  <td data-label={gettext("Received")} class="nowrap">
                    {message_time(r["inserted_at"])}
                  </td>
                  <td data-label={gettext("Replies")}>{r["replies"]}</td>
                </tr>
              </tbody>
            </table>
            <.pager page={page} path={pager_path(@query)} />
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
      active={:support}
    >
      <div class="space-y-6">
        <.link navigate={~p"/admin/support"} class="link text-sm">← {gettext("All requests")}</.link>
        <%= case @request do %>
          <% :loading -> %>
            <p class="text-muted">{gettext("Loading…")}</p>
          <% :not_found -> %>
            <.access_state
              id="support-not-found"
              icon="hero-lifebuoy"
              tone="info"
              title={gettext("This request doesn't exist anymore")}
            >
              {gettext(
                "It may have been deleted with its author's account, or by the retention rule (180 days after closing)."
              )}
            </.access_state>
          <% :unavailable -> %>
            <.unavailable id="support-request-unavailable">
              {gettext("This request can't be loaded right now.")}
            </.unavailable>
          <% r -> %>
            <.page_header eyebrow={ContactLive.topic_label(r["topic"])} title={r["reference"]}>
              {gettext("Received %{date}", date: datetime(r["inserted_at"]))}
            </.page_header>
            <div class="flex flex-wrap items-center gap-3">
              <.status_tag status={r["status"]} />
              <span class="text-sm text-muted">
                {gettext("Language of the request: %{locale}",
                  locale: String.upcase(r["locale"] || "en")
                )}
              </span>
            </div>
            <p id="support-audit-note" class="text-xs text-muted">
              {gettext("Opening this request was recorded in the audit log.")}
            </p>

            <section class="card space-y-3" aria-labelledby="support-from-title">
              <h2 id="support-from-title" class="text-xl">{gettext("From")}</h2>
              <p><.requester requester={r["requester"]} /></p>
            </section>

            <section class="card space-y-3" aria-labelledby="support-message-title">
              <h2 id="support-message-title" class="text-xl">{gettext("Message")}</h2>
              <p id="support-message" class="whitespace-pre-wrap break-words">{r["message"]}</p>
            </section>

            <section class="card space-y-4" aria-labelledby="support-replies-title">
              <h2 id="support-replies-title" class="text-xl">{gettext("Replies")}</h2>
              <p :if={r["replies"] == []} class="text-sm text-muted">{gettext("No reply yet.")}</p>
              <ol :if={r["replies"] != []} class="timeline" id="support-replies">
                <li :for={reply <- r["replies"]} id={"support-reply-#{reply["id"]}"} class="space-y-1">
                  <p class="text-xs text-muted">
                    {message_time(reply["inserted_at"])} · <.person person={reply["author"]} /> ·
                    <span :if={reply["email_status"] == "sent"}>{gettext("e-mail sent")}</span>
                    <span :if={reply["email_status"] != "sent"} class="text-danger">
                      {gettext("e-mail not sent")}
                    </span>
                  </p>
                  <p class="whitespace-pre-wrap text-sm">{reply["body"]}</p>
                </li>
              </ol>

              <%= if r["status"] == "closed" do %>
                <p id="support-closed-note" class="text-sm text-muted">
                  {gettext("This request is closed: reopen it below to answer.")}
                </p>
              <% else %>
                <.form for={@reply_form} id="support-reply-form" phx-submit="reply" class="space-y-3">
                  <.input
                    field={@reply_form[:body]}
                    type="textarea"
                    rows="6"
                    maxlength="5000"
                    label={gettext("Your reply")}
                    hint={
                      gettext(
                        "Sent by e-mail to the requester, with the reference, without their original message."
                      )
                    }
                    required
                  />
                  <.button type="submit" id="send-reply" phx-disable-with={gettext("Sending…")}>
                    <.icon name="hero-paper-airplane" /> {gettext("Send the reply by e-mail")}
                  </.button>
                </.form>
              <% end %>
            </section>

            <section class="card space-y-4" aria-labelledby="support-manage-title">
              <h2 id="support-manage-title" class="text-xl">{gettext("Status and internal note")}</h2>
              <.form for={@manage_form} id="support-manage-form" phx-submit="manage" class="space-y-4">
                <.input
                  field={@manage_form[:status]}
                  type="select"
                  label={gettext("Status")}
                  options={for s <- ~w(open answered closed), do: {status_label(s), s}}
                />
                <.input
                  field={@manage_form[:internal_note]}
                  type="textarea"
                  rows="3"
                  maxlength="4000"
                  label={gettext("Internal note")}
                  hint={
                    gettext(
                      "Seen by the staff only, never sent to the requester; a member finds it in their data export."
                    )
                  }
                />
                <.button type="submit" id="save-support" variant="secondary">{gettext("Save")}</.button>
              </.form>
            </section>

            <section
              :if={MysticWeb.Admin.Guard.admin?(@current_user)}
              class="card space-y-3"
              aria-labelledby="support-erase-title"
              id="support-erase"
            >
              <h2 id="support-erase-title" class="text-xl">{gettext("Erase this request")}</h2>
              <p class="text-sm text-muted">
                {gettext(
                  "For an erasure request, for example from a visitor (who has no account to delete). The request and its replies are deleted at once; the audit log keeps its reference, never its text."
                )}
              </p>
              <.button
                type="button"
                variant="danger"
                id="erase-support"
                phx-click="delete"
                data-confirm={gettext("Erase this request and its replies for good?")}
              >
                <.icon name="hero-trash" /> {gettext("Erase")}
              </.button>
            </section>
        <% end %>
      </div>
    </Layouts.admin>
    """
  end
end
