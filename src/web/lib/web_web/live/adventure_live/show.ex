defmodule MysticWeb.AdventureLive.Show do
  @moduledoc "Adventure detail: objectives, chapters (completed lessons ticked) and the right call to action."
  use MysticWeb, :live_view

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    {:ok, socket |> assign(slug: slug, premium_needed: false) |> load()}
  end

  defp load(socket) do
    case Api.get(socket, :learning, "/api/adventures/:slug",
           path_params: [slug: socket.assigns.slug]
         ) do
      {:ok, %{"slug" => _} = adventure} ->
        assign(socket, adventure: adventure, page_title: adventure["title"])

      {:error, {:http, 404, _}} ->
        raise MysticWeb.NotFoundError

      _ ->
        assign(socket, adventure: :unavailable, page_title: gettext("Adventure"))
    end
  end

  @impl true
  def handle_event("enroll", _params, socket) do
    slug = socket.assigns.slug

    case Api.post(socket, :learning, "/api/adventures/:slug/enroll", path_params: [slug: slug]) do
      {:ok, _} ->
        case start_lesson(socket.assigns.adventure) do
          nil -> {:noreply, socket |> put_flash(:info, gettext("You're enrolled!")) |> load()}
          lesson_id -> {:noreply, push_navigate(socket, to: ~p"/learn/#{slug}/#{lesson_id}")}
        end

      {:error, {:http, 402, _}} ->
        {:noreply, assign(socket, premium_needed: true)}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  defp start_lesson(adventure) do
    adventure["resume_lesson_id"] ||
      Enum.find_value(adventure["chapters"] || [], fn ch ->
        Enum.find_value(ch["lessons"] || [], &(&1["completed"] != true && &1["id"]))
      end) ||
      get_in(adventure, ["chapters", Access.at(0), "lessons", Access.at(0), "id"])
  end

  defp lesson_count(adventure),
    do:
      adventure["chapters"] |> List.wrap() |> Enum.map(&length(&1["lessons"] || [])) |> Enum.sum()

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
      <%= if @adventure == :unavailable do %>
        <div class="space-y-6">
          <.link navigate={~p"/adventures"} class="link">← {gettext("All adventures")}</.link>
          <.unavailable id="adventure-unavailable">
            {gettext("This adventure can't be loaded right now.")}
          </.unavailable>
        </div>
      <% else %>
        <article class="space-y-10">
          <nav aria-label={gettext("Breadcrumb")} class="breadcrumb">
            <.link navigate={~p"/adventures"}>{gettext("Adventures")}</.link>
            <span aria-hidden="true">/</span>
            <span aria-current="page" class="truncate">{@adventure["title"]}</span>
          </nav>

          <section class="grid gap-8 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)] lg:items-center">
            <.art cover={@adventure["cover"]} class="aspect-[16/10] rounded-panel" loading="eager" />
            <div class="space-y-5">
              <div class="flex flex-wrap gap-2">
                <.tag>{category_label(@adventure["category"])}</.tag>
                <.tag>{difficulty_label(@adventure["difficulty"])}</.tag>
                <.access_tag premium={@adventure["premium"] == true} />
              </div>
              <h1 class="break-words text-5xl md:text-6xl">{@adventure["title"]}</h1>
              <p class="text-lg text-muted">{@adventure["summary"]}</p>
              <ul class="flex flex-wrap gap-x-6 gap-y-2 text-sm text-muted">
                <li :if={is_integer(@adventure["duration_minutes"])} class="meta">
                  <.icon name="hero-clock" class="size-4" />
                  {ngettext("%{count} minute", "%{count} minutes", @adventure["duration_minutes"])}
                </li>
                <li class="meta">
                  <.icon name="hero-bookmark" class="size-4" />
                  {ngettext(
                    "%{count} chapter",
                    "%{count} chapters",
                    length(@adventure["chapters"] || [])
                  )}
                </li>
                <li class="meta">
                  <.icon name="hero-document-text" class="size-4" />
                  {ngettext("%{count} lesson", "%{count} lessons", lesson_count(@adventure))}
                </li>
              </ul>
              <div id="adventure-cta" class="card space-y-4">
                <.cta
                  adventure={@adventure}
                  current_user={@current_user}
                  premium_needed={@premium_needed}
                />
              </div>
            </div>
          </section>

          <div class="grid gap-8 lg:grid-cols-[minmax(0,1fr)_22rem]">
            <div class="space-y-8">
              <section :if={@adventure["description"]} class="space-y-3" aria-labelledby="about-title">
                <h2 id="about-title" class="text-3xl">{gettext("About this adventure")}</h2>
                <p class="whitespace-pre-line text-muted">{@adventure["description"]}</p>
              </section>

              <section class="space-y-4" aria-labelledby="chapters-title">
                <h2 id="chapters-title" class="text-3xl">{gettext("Chapters")}</h2>
                <ol id="chapters" class="space-y-4">
                  <li :for={chapter <- @adventure["chapters"] || []} class="card space-y-3">
                    <h3 class="text-2xl">
                      <span class="text-muted">{gettext("Chapter %{n}", n: chapter["position"])} ·</span>
                      {chapter["title"]}
                    </h3>
                    <ol class="divide-y divide-line">
                      <li
                        :for={lesson <- chapter["lessons"] || []}
                        id={"lesson-#{lesson["id"]}"}
                        class="lesson-row"
                      >
                        <.icon
                          name={
                            if lesson["completed"],
                              do: "hero-check-circle-solid",
                              else: kind_icon(lesson["kind"])
                          }
                          class={[
                            "size-5 shrink-0",
                            if(lesson["completed"], do: "text-success", else: "text-muted")
                          ]}
                        />
                        <div class="min-w-0 flex-1">
                          <%= if @adventure["access"] == "open" do %>
                            <.link
                              navigate={~p"/learn/#{@adventure["slug"]}/#{lesson["id"]}"}
                              class="font-medium hover:text-magic"
                            >
                              {lesson["title"]}
                            </.link>
                          <% else %>
                            <span class="font-medium">{lesson["title"]}</span>
                          <% end %>
                          <p class="text-xs text-muted">
                            {kind_label(lesson["kind"])} · {gettext("%{xp} XP",
                              xp: lesson["xp_reward"]
                            )}
                          </p>
                        </div>
                        <span :if={lesson["completed"]} class="text-xs font-medium text-success">
                          {gettext("Completed")}
                        </span>
                      </li>
                    </ol>
                  </li>
                </ol>
              </section>
            </div>

            <aside class="space-y-6">
              <section
                :if={(@adventure["objectives"] || []) != []}
                class="card space-y-3"
                aria-labelledby="objectives-title"
              >
                <h2 id="objectives-title" class="text-2xl">{gettext("What you'll learn")}</h2>
                <ul class="space-y-2 text-sm">
                  <li :for={objective <- @adventure["objectives"]} class="flex gap-2">
                    <.icon name="hero-sparkles" class="mt-0.5 size-4 shrink-0 text-reward" />
                    <span>{objective}</span>
                  </li>
                </ul>
              </section>
              <section class="card space-y-3" aria-labelledby="prereq-title">
                <h2 id="prereq-title" class="text-2xl">{gettext("Before you start")}</h2>
                <ul :if={(@adventure["prerequisites"] || []) != []} class="space-y-2 text-sm">
                  <li :for={prerequisite <- @adventure["prerequisites"]} class="flex gap-2">
                    <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-info" />
                    <span>{prerequisite}</span>
                  </li>
                </ul>
                <p :if={(@adventure["prerequisites"] || []) == []} class="text-sm text-muted">
                  {gettext("No prerequisites — curiosity is enough.")}
                </p>
              </section>
            </aside>
          </div>
        </article>
      <% end %>
    </Layouts.app>
    """
  end

  attr :adventure, :map, required: true
  attr :current_user, :map, default: nil
  attr :premium_needed, :boolean, default: false

  defp cta(assigns) do
    ~H"""
    <%= cond do %>
      <% @current_user == nil or @adventure["access"] == "login_required" -> %>
        <p class="text-sm text-muted">
          {gettext("Log in to start this adventure and keep your progress.")}
        </p>
        <div class="flex flex-wrap gap-2">
          <.button href={~p"/login"} id="cta-login">{gettext("Log in to start")}</.button>
          <.button href={~p"/register"} variant="secondary">{gettext("Create an account")}</.button>
        </div>
      <% @premium_needed or @adventure["access"] == "premium_required" -> %>
        <p class="flex items-center gap-2 font-medium text-reward">
          <.icon name="hero-lock-closed" /> {gettext("Premium adventure")}
        </p>
        <p class="text-sm text-muted">
          {gettext("Upgrade your membership to unlock every chapter.")}
        </p>
        <.button navigate={~p"/membership"} variant="reward" id="cta-upgrade">
          <.icon name="hero-sparkles" /> {gettext("Upgrade to unlock")}
        </.button>
      <% @adventure["enrolled"] -> %>
        <div :if={@adventure["progress"]} class="space-y-2">
          <p class="flex justify-between text-sm">
            <span>{gettext("Your progress")}</span>
            <span class="tabular-nums text-muted">
              {gettext("%{done} of %{total} lessons",
                done: @adventure["progress"]["done"],
                total: @adventure["progress"]["total"]
              )}
            </span>
          </p>
          <.progress
            value={@adventure["progress"]["percent"] || 0}
            label={gettext("Adventure progress")}
          />
        </div>
        <.button
          :if={start_lesson(@adventure)}
          navigate={~p"/learn/#{@adventure["slug"]}/#{start_lesson(@adventure)}"}
          id="cta-resume"
        >
          {gettext("Resume the adventure")} <.icon name="hero-arrow-right" />
        </.button>
      <% true -> %>
        <p class="text-sm text-muted">
          {gettext("Enroll to save your progress, earn XP and resume anytime.")}
        </p>
        <.button phx-click="enroll" id="cta-enroll" phx-disable-with={gettext("Enrolling…")}>
          {gettext("Enroll and start")} <.icon name="hero-arrow-right" />
        </.button>
    <% end %>
    """
  end
end
