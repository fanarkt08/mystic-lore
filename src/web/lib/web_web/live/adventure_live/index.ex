defmodule MysticWeb.AdventureLive.Index do
  @moduledoc "Catalogue: search, filters, sort and pagination, all kept in the URL (push_patch)."
  use MysticWeb, :live_view

  @choices %{
    "category" => ~w(coding science humanities creative),
    "difficulty" => ~w(beginner intermediate advanced),
    "access" => ~w(free premium),
    "sort" => ~w(title newest shortest)
  }

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Adventures"))}

  @impl true
  def handle_params(params, _uri, socket) do
    filters = clean(params)

    result =
      case Api.get(socket, :learning, "/api/adventures", params: Map.to_list(filters)) do
        {:ok, %{"entries" => entries} = page} when is_list(entries) -> page
        _ -> :unavailable
      end

    {:noreply,
     assign(socket, filters: filters, form: to_form(filters, as: :filters), result: result)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    # Changing a filter always goes back to the first page.
    {:noreply, push_patch(socket, to: path(Map.delete(clean(params), "page")))}
  end

  defp clean(params) do
    filters =
      for {key, allowed} <- @choices, params[key] in allowed, into: %{}, do: {key, params[key]}

    q = params["q"] |> to_string() |> String.trim() |> String.slice(0, 80)

    page =
      case Integer.parse(to_string(params["page"])) do
        {n, ""} when n > 1 -> n
        _ -> nil
      end

    filters
    |> then(&if(q != "", do: Map.put(&1, "q", q), else: &1))
    |> then(&if(page, do: Map.put(&1, "page", page), else: &1))
  end

  defp path(filters) do
    case Map.reject(filters, &match?({"page", 1}, &1)) do
      params when params == %{} -> ~p"/adventures"
      params -> ~p"/adventures?#{params}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      current_path={@current_path}
      active={:adventures}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Catalogue")} title={gettext("Adventures")}>
          {gettext("Choose your next journey by subject, difficulty or length.")}
        </.page_header>

        <.form
          for={@form}
          id="filters"
          phx-change="filter"
          phx-submit="filter"
          class="filters"
          role="search"
        >
          <div class="filters-search">
            <.input
              field={@form[:q]}
              type="search"
              label={gettext("Search")}
              placeholder={gettext("Title or theme…")}
              phx-debounce="300"
            />
          </div>
          <.input
            field={@form[:category]}
            type="select"
            label={gettext("Category")}
            prompt={gettext("All categories")}
            options={Enum.map(~w(coding science humanities creative), &{category_label(&1), &1})}
          />
          <.input
            field={@form[:difficulty]}
            type="select"
            label={gettext("Difficulty")}
            prompt={gettext("All levels")}
            options={Enum.map(~w(beginner intermediate advanced), &{difficulty_label(&1), &1})}
          />
          <.input
            field={@form[:access]}
            type="select"
            label={gettext("Access")}
            prompt={gettext("All access")}
            options={[{gettext("Free"), "free"}, {gettext("Premium"), "premium"}]}
          />
          <.input
            field={@form[:sort]}
            type="select"
            label={gettext("Sort by")}
            options={[
              {gettext("Title (A–Z)"), "title"},
              {gettext("Newest"), "newest"},
              {gettext("Shortest"), "shortest"}
            ]}
          />
        </.form>

        <p id="results-count" class="text-sm text-muted" aria-live="polite">
          <%= if is_map(@result) do %>
            {ngettext("%{count} adventure found", "%{count} adventures found", @result["total"] || 0)}
          <% end %>
        </p>

        <%= case @result do %>
          <% :unavailable -> %>
            <.unavailable id="catalogue-unavailable">
              {gettext("The catalogue can't be loaded right now.")}
            </.unavailable>
          <% %{"entries" => []} -> %>
            <.empty_state
              id="catalogue-empty"
              icon="hero-magnifying-glass"
              title={gettext("No adventure matches these filters")}
            >
              {gettext("Try another word or loosen a filter.")}
              <:actions>
                <.button patch={~p"/adventures"} variant="secondary">{gettext("Clear filters")}</.button>
              </:actions>
            </.empty_state>
          <% page -> %>
            <div id="adventure-grid" class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
              <.adventure_card
                :for={adventure <- page["entries"]}
                id={"adventure-#{adventure["slug"]}"}
                adventure={adventure}
                heading="h2"
              />
            </div>
            <nav
              :if={(page["total_pages"] || 1) > 1}
              id="pagination"
              class="flex flex-wrap items-center justify-between gap-3"
              aria-label={gettext("Pagination")}
            >
              <.button
                :if={page["page"] > 1}
                patch={path(Map.put(@filters, "page", page["page"] - 1))}
                variant="secondary"
                id="page-prev"
              >
                <.icon name="hero-arrow-left" /> {gettext("Previous")}
              </.button>
              <span :if={page["page"] <= 1}></span>
              <p class="text-sm text-muted" aria-current="page">
                {gettext("Page %{page} of %{total}", page: page["page"], total: page["total_pages"])}
              </p>
              <.button
                :if={page["page"] < page["total_pages"]}
                patch={path(Map.put(@filters, "page", page["page"] + 1))}
                variant="secondary"
                id="page-next"
              >
                {gettext("Next")} <.icon name="hero-arrow-right" />
              </.button>
              <span :if={page["page"] >= page["total_pages"]}></span>
            </nav>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
