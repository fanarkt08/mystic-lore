defmodule MysticWeb.FriendsLive do
  @moduledoc "Friends, requests, member search and blocks, reloaded in real time."
  use MysticWeb, :live_view
  alias MysticWeb.{Presence, Social}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Presence.subscribe()

    {:ok,
     socket
     |> assign(page_title: gettext("Friends"))
     |> assign(query: "", results: nil, reporting: nil)
     |> assign(online: if(connected?(socket), do: Presence.online_ids(), else: MapSet.new()))
     |> load()}
  end

  defp load(socket), do: assign(socket, rel: Social.relations(socket))

  @impl true
  def handle_info({:friendship_changed, _user_id}, socket), do: {:noreply, load(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, online: Presence.online_ids())}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    q = q |> String.trim() |> String.slice(0, 50)

    results =
      if String.length(q) >= 2 do
        case Api.get(socket, :accounts, "/api/users/search", params: [q: q]) do
          {:ok, %{"users" => users}} -> users
          _ -> :unavailable
        end
      end

    {:noreply, assign(socket, query: q, results: results)}
  end

  def handle_event("message", %{"id" => user_id}, socket) do
    case Social.open_conversation(socket, user_id) do
      {:ok, id} -> {:noreply, push_navigate(socket, to: ~p"/messages/#{id}")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("report", %{"id" => user_id}, socket),
    do: {:noreply, assign(socket, reporting: find_user(socket, user_id))}

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: nil)}

  def handle_event("submit_report", %{"report" => params}, socket) do
    case Social.report(socket, socket.assigns.reporting["id"], params) do
      {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> assign(reporting: nil)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(action, %{"id" => id}, socket) do
    if action in Social.actions() do
      socket =
        case Social.act(socket, action, id) do
          {:ok, message} -> put_flash(socket, :info, message)
          {:error, message} -> put_flash(socket, :error, message)
        end

      {:noreply, load(socket)}
    else
      {:noreply, socket}
    end
  end

  defp find_user(socket, id) do
    rel = if is_map(socket.assigns.rel), do: socket.assigns.rel, else: %{}

    [
      rel[:friends] || [],
      rel[:blocks] || [],
      Enum.map(rel[:incoming] || [], & &1["from"]),
      Enum.map(rel[:outgoing] || [], & &1["to"]),
      List.wrap(if is_list(socket.assigns.results), do: socket.assigns.results)
    ]
    |> Enum.concat()
    |> Enum.find(&(&1["id"] == id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:friends}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Companions")} title={gettext("Friends")}>
          {gettext("Find classmates, answer requests and keep your circle safe.")}
          <:actions>
            <.button navigate={~p"/messages/new"} variant="secondary" id="friends-new-group">
              <.icon name="hero-user-group" /> {gettext("New group")}
            </.button>
          </:actions>
        </.page_header>

        <Social.report_panel :if={@reporting} user={@reporting} />

        <section class="card space-y-4" aria-labelledby="search-title">
          <h2 id="search-title" class="text-2xl">{gettext("Find members")}</h2>
          <.form for={%{}} id="member-search" phx-change="search" phx-submit="search" role="search">
            <.input
              id="search-q"
              name="q"
              value={@query}
              type="search"
              label={gettext("Username or display name")}
              hint={gettext("Type at least 2 characters.")}
              phx-debounce="300"
              autocomplete="off"
            />
          </.form>
          <div id="search-results" aria-live="polite">
            <%= case @results do %>
              <% nil -> %>
              <% :unavailable -> %>
                <.unavailable>{gettext("Member search is unavailable right now.")}</.unavailable>
              <% [] -> %>
                <p class="text-sm text-muted">{gettext("No member matches “%{q}”.", q: @query)}</p>
              <% users -> %>
                <ul class="divide-y divide-line">
                  <li :for={user <- users} id={"result-#{user["id"]}"} class="member-row">
                    <.member user={user} />
                    <Social.member_actions
                      user={user}
                      relation={Social.relation(@rel, user["id"])}
                      compact
                    />
                  </li>
                </ul>
            <% end %>
          </div>
        </section>

        <%= if @rel == :unavailable do %>
          <.unavailable id="friends-unavailable">
            {gettext("Your friends can't be loaded right now.")}
          </.unavailable>
        <% else %>
          <div class="grid gap-6 lg:grid-cols-2">
            <section class="card space-y-4" aria-labelledby="incoming-title">
              <h2 id="incoming-title" class="text-2xl">{gettext("Requests received")}</h2>
              <p :if={@rel.incoming == []} class="text-sm text-muted">
                {gettext("No pending requests.")}
              </p>
              <ul class="divide-y divide-line">
                <li
                  :for={request <- @rel.incoming}
                  id={"incoming-#{request["id"]}"}
                  class="member-row"
                >
                  <.member user={request["from"]} />
                  <div class="flex flex-wrap gap-2">
                    <.button phx-click="accept" phx-value-id={request["id"]}>{gettext("Accept")}</.button>
                    <.button phx-click="decline" phx-value-id={request["id"]} variant="ghost">{gettext(
                      "Decline"
                    )}</.button>
                  </div>
                </li>
              </ul>
            </section>

            <section class="card space-y-4" aria-labelledby="outgoing-title">
              <h2 id="outgoing-title" class="text-2xl">{gettext("Requests sent")}</h2>
              <p :if={@rel.outgoing == []} class="text-sm text-muted">
                {gettext("No request waiting for an answer.")}
              </p>
              <ul class="divide-y divide-line">
                <li
                  :for={request <- @rel.outgoing}
                  id={"outgoing-#{request["id"]}"}
                  class="member-row"
                >
                  <.member user={request["to"]} />
                  <.button phx-click="cancel" phx-value-id={request["id"]} variant="ghost">{gettext(
                    "Cancel request"
                  )}</.button>
                </li>
              </ul>
            </section>
          </div>

          <section class="card space-y-4" aria-labelledby="friends-title">
            <h2 id="friends-title" class="text-2xl">
              {gettext("My friends")} <span class="text-muted">({length(@rel.friends)})</span>
            </h2>
            <p :if={@rel.friends == []} class="text-sm text-muted">
              {gettext("No friends yet — search for members above to send a request.")}
            </p>
            <ul class="divide-y divide-line" id="friends-list">
              <li :for={friend <- @rel.friends} id={"friend-#{friend["id"]}"} class="member-row">
                <.member
                  user={friend}
                  online={MapSet.member?(Presence.visible(@rel.friends, @online), friend["id"])}
                />
                <Social.member_actions user={friend} relation={:friend} />
              </li>
            </ul>
          </section>

          <section :if={@rel.blocks != []} class="card space-y-4" aria-labelledby="blocked-title">
            <h2 id="blocked-title" class="text-2xl">{gettext("Blocked members")}</h2>
            <ul class="divide-y divide-line">
              <li :for={user <- @rel.blocks} id={"blocked-#{user["id"]}"} class="member-row">
                <.member user={user} />
                <.button phx-click="unblock" phx-value-id={user["id"]} variant="secondary">{gettext(
                  "Unblock"
                )}</.button>
              </li>
            </ul>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :user, :map, required: true
  attr :online, :boolean, default: false

  defp member(assigns) do
    ~H"""
    <div class="flex min-w-48 flex-1 items-center gap-3">
      <span class="avatar-wrap">
        <.avatar user={@user} />
        <MysticWeb.MessagesComponents.online_dot :if={@online} />
      </span>
      <div class="min-w-0">
        <.link
          navigate={~p"/members/#{@user["username"]}"}
          class="block break-words font-medium hover:text-magic"
        >
          {@user["display_name"]}
        </.link>
        <p class="break-words text-xs text-muted">@{@user["username"]}</p>
      </div>
    </div>
    """
  end
end
