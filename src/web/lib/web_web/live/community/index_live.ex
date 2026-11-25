defmodule MysticWeb.Community.IndexLive do
  @moduledoc "Forum home with search, filters and sort kept in the URL."
  use MysticWeb, :live_view
  import MysticWeb.CommunityComponents

  @filters ~w(unanswered solved following)
  @sorts ~w(recent helpful)

  @impl true
  def mount(_params, _session, socket) do
    categories =
      case Api.get(socket, :community, "/api/categories") do
        {:ok, %{"categories" => list}} when is_list(list) -> list
        _ -> []
      end

    {:ok, assign(socket, page_title: gettext("Community"), categories: categories)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = clean(params, socket)

    result =
      case Api.get(socket, :community, "/api/discussions", params: Map.to_list(filters)) do
        {:ok, %{"entries" => entries} = page} when is_list(entries) -> page
        error -> {:unavailable, community_error(error)}
      end

    {:noreply,
     assign(socket, filters: filters, form: to_form(filters, as: :filters), result: result)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    # Changing a filter always goes back to the first page.
    {:noreply, push_patch(socket, to: path(Map.delete(clean(params, socket), "page")))}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp clean(params, socket) do
    member? = socket.assigns.current_user != nil
    slugs = Enum.map(socket.assigns.categories, & &1["slug"])
    q = params["q"] |> to_string() |> String.trim() |> String.slice(0, 100)

    page =
      case Integer.parse(to_string(params["page"])) do
        {n, ""} when n > 1 -> n
        _ -> nil
      end

    [
      {"q", q != "" && q},
      {"category", params["category"] in slugs && params["category"]},
      {"filter",
       (params["filter"] in @filters and (member? or params["filter"] != "following")) &&
         params["filter"]},
      {"sort", (params["sort"] in @sorts and params["sort"] != "recent") && params["sort"]},
      {"page", page}
    ]
    |> Enum.filter(fn {_key, value} -> value end)
    |> Map.new()
  end

  defp path(filters) do
    case Map.reject(filters, &match?({"page", 1}, &1)) do
      params when params == %{} -> ~p"/community"
      params -> ~p"/community?#{params}"
    end
  end

  defp active_filters(filters), do: filters |> Map.drop(["page"]) |> map_size()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      current_path={@current_path}
      active={:community}
    >
      <div class="space-y-6">
        <div>
          <.page_header eyebrow={gettext("Forum")} title={gettext("Community")}>
            {gettext("Ask for help, share what you made and find companions for your next adventure.")}
            <:actions>
              <.button :if={@current_user} navigate={~p"/community/new"} id="new-discussion">
                <.icon name="hero-plus" /> {gettext("New discussion")}
              </.button>
              <.button :if={!@current_user} href={~p"/login"} variant="secondary" id="login-to-post">
                {gettext("Log in to post")}
              </.button>
            </:actions>
          </.page_header>
        </div>

        <section id="community-filters" class="community-filters">
          <button
            type="button"
            class="btn btn-secondary community-filters-toggle"
            aria-controls="filters"
            aria-expanded="false"
            phx-click={
              JS.toggle_class("is-open", to: "#community-filters")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            }
          >
            <.icon name="hero-funnel" />
            {gettext("Search and filters")}
            <.count_badge
              count={active_filters(@filters)}
              label={gettext("active filters")}
              class="ml-auto"
            />
          </button>
          <.form
            for={@form}
            id="filters"
            phx-change="filter"
            phx-submit="filter"
            class="community-filter-form"
            role="search"
          >
            <.input
              field={@form[:q]}
              type="search"
              label={gettext("Search")}
              placeholder={gettext("Title or text…")}
              maxlength="100"
              phx-debounce="300"
            />
            <.input
              field={@form[:category]}
              type="select"
              label={gettext("Category")}
              prompt={gettext("All categories")}
              options={Enum.map(@categories, &{category_name(&1), &1["slug"]})}
            />
            <.input
              field={@form[:filter]}
              type="select"
              label={gettext("Show")}
              prompt={gettext("All discussions")}
              options={
                [{gettext("Unanswered"), "unanswered"}, {gettext("Solved"), "solved"}] ++
                  if(@current_user, do: [{gettext("Followed by me"), "following"}], else: [])
              }
            />
            <.input
              field={@form[:sort]}
              type="select"
              label={gettext("Sort by")}
              options={[{gettext("Latest activity"), "recent"}, {gettext("Most helpful"), "helpful"}]}
            />
          </.form>
        </section>

        <p id="results-count" class="text-sm text-muted" aria-live="polite">
          <%= if is_map(@result) do %>
            {ngettext("%{count} discussion", "%{count} discussions", @result["total"] || 0)}
          <% end %>
        </p>

        <%= case @result do %>
          <% {:unavailable, message} -> %>
            <.notice
              id="community-unavailable"
              kind="warning"
              title={gettext("Temporarily unavailable")}
            >
              {message}
            </.notice>
          <% %{"entries" => []} -> %>
            <.empty_state
              :if={active_filters(@filters) > 0}
              id="community-empty"
              icon="hero-magnifying-glass"
              title={gettext("No discussion matches these filters")}
            >
              {gettext("Try another word or loosen a filter.")}
              <:actions>
                <.button patch={~p"/community"} variant="secondary">{gettext("Clear filters")}</.button>
              </:actions>
            </.empty_state>
            <.empty_state
              :if={active_filters(@filters) == 0}
              id="community-empty"
              icon="hero-chat-bubble-left-right"
              title={gettext("No discussion yet")}
            >
              {gettext("Be the first to start a conversation.")}
              <:actions :if={@current_user}>
                <.button navigate={~p"/community/new"}>{gettext("Start a discussion")}</.button>
              </:actions>
            </.empty_state>
          <% page -> %>
            <ul id="discussions" class="discussion-list">
              <li :for={discussion <- page["entries"]}>
                <.discussion_card id={"discussion-#{discussion["slug"]}"} discussion={discussion} />
              </li>
            </ul>
            <.pager
              id="pagination"
              page={page["page"] || 1}
              total_pages={page["total_pages"] || 1}
              path={&path(Map.put(@filters, "page", &1))}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
