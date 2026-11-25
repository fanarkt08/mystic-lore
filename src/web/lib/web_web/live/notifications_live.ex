defmodule MysticWeb.NotificationsLive do
  @moduledoc "The member's notifications, with each text and link built here from `kind` and `params`."
  use MysticWeb, :live_view
  alias MysticWeb.Notifications

  @page 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Notifications"),
       toast_except: :all,
       filter: "all",
       entries: [],
       next_before: nil,
       unread_total: 0,
       state: :loading
     )}
  end

  @impl true
  def handle_params(%{"open" => id}, _uri, socket) when is_binary(id) do
    case Api.post(socket, :notifications, "/api/me/notifications/:id/read", path_params: [id: id]) do
      {:ok, %{"notification" => %{"id" => _} = n}} ->
        {:noreply, push_navigate(socket, to: Notifications.path(n), replace: true)}

      {:error, {:http, 404, _}} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This notification no longer exists."))
         |> push_patch(to: ~p"/notifications", replace: true)}

      error ->
        {:noreply,
         socket
         |> put_flash(:error, Api.error_message(error))
         |> push_patch(to: ~p"/notifications", replace: true)}
    end
  end

  def handle_params(params, _uri, socket) do
    filter = if params["filter"] == "unread", do: "unread", else: "all"
    {:noreply, socket |> assign(filter: filter, entries: [], next_before: nil) |> load(@page)}
  end

  # First page (or as many entries as already shown, 50 at most, after a live change).
  defp load(socket, limit) do
    case fetch(socket, limit: limit) do
      {:ok, page} ->
        assign(socket,
          state: :ok,
          entries: page["entries"],
          next_before: page["next_before"],
          unread_total: page["unread"] || 0
        )

      :error ->
        assign(socket, state: :unavailable, entries: [], next_before: nil)
    end
  end

  defp fetch(socket, opts) do
    params = [filter: socket.assigns.filter, limit: opts[:limit] || @page]
    params = if opts[:before], do: Keyword.put(params, :before, opts[:before]), else: params

    case Api.get(socket, :notifications, "/api/me/notifications", params: params) do
      {:ok, %{"entries" => entries} = page} when is_list(entries) ->
        {:ok, %{page | "entries" => Notifications.enrich(socket, entries)}}

      _ ->
        :error
    end
  end

  @impl true
  def handle_event("read", %{"id" => id}, socket) do
    case Api.post(socket, :notifications, "/api/me/notifications/:id/read", path_params: [id: id]) do
      {:ok, _} -> {:noreply, reload(socket)}
      error -> {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("read_all", _params, socket) do
    case Api.post(socket, :notifications, "/api/me/notifications/read-all") do
      {:ok, %{"read" => _}} ->
        {:noreply,
         socket |> put_flash(:info, gettext("All your notifications are read.")) |> reload()}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("load_more", _params, %{assigns: %{next_before: cursor}} = socket)
      when is_binary(cursor) do
    case fetch(socket, before: cursor) do
      {:ok, page} ->
        {:noreply,
         assign(socket,
           entries: socket.assigns.entries ++ page["entries"],
           next_before: page["next_before"],
           unread_total: page["unread"] || socket.assigns.unread_total
         )}

      :error ->
        {:noreply, put_flash(socket, :error, Api.error_message(:unavailable))}
    end
  end

  def handle_event("load_more", _params, socket), do: {:noreply, socket}

  defp reload(socket),
    do: load(socket, socket.assigns.entries |> length() |> max(@page) |> min(50))

  @impl true
  def handle_info({:notifications_changed, _user_id, _toast}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:notifications}
    >
      <div class="mx-auto max-w-3xl space-y-6">
        <.page_header eyebrow={gettext("Your academy")} title={gettext("Notifications")}>
          {gettext("What happened in your conversations, groups, forum and studio, newest first.")}
          <:actions>
            <.button
              :if={@state == :ok and @unread_total > 0}
              type="button"
              variant="secondary"
              id="read-all"
              phx-click="read_all"
            >
              <.icon name="hero-check-circle" /> {gettext("Mark all as read")}
            </.button>
            <.link
              navigate={~p"/settings/notifications"}
              class="btn btn-ghost"
              id="notification-settings"
            >
              <.icon name="hero-cog-6-tooth" /> {gettext("Settings")}
            </.link>
          </:actions>
        </.page_header>

        <nav aria-label={gettext("Filter the notifications")} class="notification-filters">
          <.link
            patch={~p"/notifications"}
            id="filter-all"
            class="filter-pill"
            aria-current={@filter == "all" && "page"}
          >
            {gettext("All")}
          </.link>
          <.link
            patch={~p"/notifications?filter=unread"}
            id="filter-unread"
            class="filter-pill"
            aria-current={@filter == "unread" && "page"}
          >
            {gettext("Unread")}
            <.count_badge
              :if={@state == :ok}
              count={@unread_total}
              label={gettext("unread notifications")}
            />
          </.link>
        </nav>

        <%= case @state do %>
          <% :loading -> %>
            <p class="text-muted" id="notifications-loading">{gettext("Loading…")}</p>
          <% :unavailable -> %>
            <.unavailable id="notifications-unavailable">
              {gettext("Your notifications can't be loaded right now.")}
            </.unavailable>
          <% :ok -> %>
            <.empty_state
              :if={@entries == []}
              id="notifications-empty"
              icon="hero-bell"
              title={
                if @filter == "unread",
                  do: gettext("Nothing unread"),
                  else: gettext("No notifications yet")
              }
            >
              {gettext(
                "Messages, friend requests, forum replies, invitations and badges will appear here."
              )}
            </.empty_state>
            <ol :if={@entries != []} id="notification-list" class="notification-list">
              <.notification :for={n <- @entries} notification={n} />
            </ol>
            <div :if={@next_before} class="flex justify-center">
              <.button type="button" variant="secondary" id="load-more" phx-click="load_more">
                {gettext("Load more")}
              </.button>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :notification, :map, required: true

  defp notification(assigns) do
    ~H"""
    <li
      id={"notification-#{@notification["id"]}"}
      class={["notification-item", !@notification["read"] && "is-unread"]}
    >
      <.avatar :if={@notification["actor"]} user={@notification["actor"]} size="md" />
      <span :if={!@notification["actor"]} class="notification-icon">
        <.icon name={Notifications.icon(@notification)} class="size-5" />
      </span>
      <div class="min-w-0 flex-1 space-y-1">
        <.link
          patch={~p"/notifications?#{[open: @notification["id"]]}"}
          id={"open-#{@notification["id"]}"}
          class="notification-link"
        >
          {Notifications.text(@notification)}
        </.link>
        <p :if={detail = Notifications.detail(@notification)} class="notification-detail">
          {gettext("Reviewer's reason: %{reason}", reason: detail)}
        </p>
        <p class="text-sm text-muted">
          <span :if={!@notification["read"]} class="notification-unread-dot" aria-hidden="true"></span>
          <span :if={!@notification["read"]} class="sr-only">{gettext("Unread.")}</span>
          <time datetime={@notification["updated_at"]} title={datetime(@notification["updated_at"])}>
            {relative(@notification["updated_at"])}
          </time>
          · {Notifications.category_label(@notification["category"])}
        </p>
      </div>
      <button
        :if={!@notification["read"]}
        type="button"
        class="btn btn-ghost notification-read"
        id={"read-#{@notification["id"]}"}
        phx-click="read"
        phx-value-id={@notification["id"]}
        aria-label={gettext("Mark as read")}
        title={gettext("Mark as read")}
      >
        <.icon name="hero-check" />
      </button>
    </li>
    """
  end
end
