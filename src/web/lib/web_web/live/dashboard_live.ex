defmodule MysticWeb.DashboardLive do
  @moduledoc """
  Member dashboard. Each zone has its own source and degrades on its own when that service is unreachable.
  """
  import MysticWeb.ProfileComponents, only: [interest_categories: 1, interest_label: 1]
  use MysticWeb, :live_view
  import MysticWeb.GamificationComponents
  import MysticWeb.PrivacyComponents, only: [deletion_banner: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Dashboard"))
     |> assign(dashboard: load_dashboard(socket))
     |> assign(billing: fetch(socket, :billing, "/api/me/billing", "entitlements"))
     |> load_requests()}
  end

  defp fetch(socket, service, path, key) do
    case Api.get(socket, service, path) do
      {:ok, %{^key => _} = body} -> body
      _ -> :unavailable
    end
  end

  defp load_dashboard(socket) do
    categories = interest_categories(socket.assigns.current_user["interests"] || [])

    case Api.get(socket, :learning, "/api/me/dashboard",
           params: [categories: Enum.join(categories, ",")]
         ) do
      {:ok, %{"level" => _} = body} -> body
      _ -> :unavailable
    end
  end

  defp vip_ended_title(%{"entitlements" => %{} = entitlements}) do
    case access_end(entitlements) do
      {:ended, at} when is_binary(at) ->
        gettext("Your VIP access ended on %{date}", date: date(at))

      _ ->
        gettext("Your VIP access has ended")
    end
  end

  defp vip_ended_title(_billing), do: gettext("Your VIP access has ended")

  # The academy day (daily quests, goal, chart) ends at midnight UTC: that instant in the member's zone.
  defp quests_reset_time do
    midnight = DateTime.new!(Date.add(Date.utc_today(), 1), ~T[00:00:00], "Etc/UTC")
    time(DateTime.to_iso8601(midnight))
  end

  attr :xp, :integer, required: true
  attr :goal, :integer, required: true

  defp daily_goal(assigns) do
    ~H"""
    <p id="goal-progress" class="font-display text-3xl text-ink">
      {gettext("%{xp} / %{goal} XP today", xp: @xp, goal: @goal)}
    </p>
    <.progress
      value={@xp}
      max={@goal}
      tone="success"
      label={gettext("Progress towards today's XP goal")}
    />
    <p class="text-sm text-muted">
      {if @xp >= @goal,
        do: gettext("Goal reached — well done!"),
        else:
          gettext("%{left} XP to go. The academy day starts again at %{time}.",
            left: @goal - @xp,
            time: quests_reset_time()
          )}
    </p>
    """
  end

  defp load_requests(socket),
    do: assign(socket, requests: fetch(socket, :social, "/api/me/friend-requests", "incoming"))

  @impl true
  def handle_info({:friendship_changed, _user_id}, socket), do: {:noreply, load_requests(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_deletion", _params, socket),
    do: {:noreply, MysticWeb.Privacy.cancel_deletion(socket)}

  def handle_event(action, %{"id" => id}, socket) when action in ["accept", "decline"] do
    socket =
      case MysticWeb.Social.act(socket, action, id) do
        {:ok, message} -> put_flash(socket, :info, message)
        {:error, message} -> put_flash(socket, :error, message)
      end

    {:noreply, load_requests(socket)}
  end

  defp plan_label("premium"), do: gettext("Premium")
  defp plan_label("vip"), do: gettext("VIP")
  defp plan_label(_), do: gettext("Free")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:dashboard}
    >
      <div class="space-y-8">
        <.page_header
          eyebrow={gettext("Your journal")}
          title={gettext("Welcome back, %{name}", name: @current_user["display_name"])}
        >
          {gettext("Pick up your adventure where you left it.")}
          <:actions>
            <.button navigate={~p"/adventures"} variant="secondary">
              <.icon name="hero-map" /> {gettext("Browse adventures")}
            </.button>
          </:actions>
        </.page_header>

        <.deletion_banner user={@current_user} />

        <%!-- a VIP theme chosen while VIP, paused since the VIP access ended: said, with the next step --%>
        <.access_state
          :if={@theme_paused}
          id="vip-ended"
          icon="hero-sparkles"
          tone="reward"
          title={
            if @theme_unverified,
              do: gettext("Your VIP theme is paused"),
              else: vip_ended_title(@billing)
          }
        >
          {if @theme_unverified,
            do:
              gettext(
                "Your membership can't be verified right now, so the device setting is used until it can be."
              ),
            else:
              gettext(
                "Your VIP theme is paused and the device setting is used instead. It comes back as soon as your VIP membership is active again."
              )}
          <:actions>
            <.button navigate={~p"/membership"} variant="reward" id="vip-renew">
              <.icon name="hero-sparkles" /> {gettext("Renew VIP")}
            </.button>
            <.button navigate={~p"/settings/preferences"} variant="ghost" id="vip-change-theme">
              {gettext("Choose another theme")}
            </.button>
          </:actions>
        </.access_state>

        <div class="space-y-6">
          <div class="grid gap-6 lg:grid-cols-3">
            <section
              id="current-adventure"
              class="card space-y-4 lg:col-span-2"
              aria-labelledby="current-title"
            >
              <h2 id="current-title" class="text-2xl">{gettext("Current adventure")}</h2>
              <%= case @dashboard do %>
                <% :unavailable -> %>
                  <.unavailable>{gettext("Your progress can't be loaded right now.")}</.unavailable>
                <% %{"current" => %{} = current} -> %>
                  <p class="font-display text-3xl text-ink">{current["title"]}</p>
                  <div class="space-y-2">
                    <p class="flex justify-between text-sm text-muted">
                      <span>{gettext("Progress")}</span>
                      <span class="tabular-nums">{current["percent"]}%</span>
                    </p>
                    <.progress
                      value={current["percent"] || 0}
                      label={gettext("Progress in %{title}", title: current["title"])}
                    />
                  </div>
                  <.button
                    :if={current["resume_lesson_id"]}
                    navigate={~p"/learn/#{current["slug"]}/#{current["resume_lesson_id"]}"}
                    id="resume"
                  >
                    {gettext("Resume")} <.icon name="hero-arrow-right" />
                  </.button>
                <% _ -> %>
                  <.empty_state icon="hero-map" title={gettext("No adventure in progress")}>
                    {gettext("Choose your first journey in the catalogue.")}
                    <:actions>
                      <.button navigate={~p"/adventures"}>{gettext("Find an adventure")}</.button>
                    </:actions>
                  </.empty_state>
              <% end %>
            </section>

            <section id="level" class="card space-y-4" aria-labelledby="level-title">
              <h2 id="level-title" class="text-2xl">{gettext("Level & XP")}</h2>
              <%= if @dashboard == :unavailable do %>
                <.unavailable>{gettext("XP can't be loaded right now.")}</.unavailable>
              <% else %>
                <div class="flex items-center gap-4">
                  <span class="level-badge" aria-hidden="true">{@dashboard["level"]}</span>
                  <div>
                    <p class="font-display text-3xl text-ink">
                      {gettext("Level %{level}", level: @dashboard["level"])}
                    </p>
                    <p class="text-sm text-muted">
                      {gettext("%{xp} XP in total", xp: @dashboard["xp"])}
                    </p>
                  </div>
                </div>
                <.progress
                  value={@dashboard["into_level"] || 0}
                  max={@dashboard["per_level"] || 1}
                  tone="reward"
                  label={gettext("XP towards the next level")}
                />
                <p class="text-sm text-muted">
                  {gettext("%{into} / %{per} XP to level %{next}",
                    into: @dashboard["into_level"],
                    per: @dashboard["per_level"],
                    next: (@dashboard["level"] || 0) + 1
                  )}
                </p>
              <% end %>
            </section>
          </div>

          <section id="daily-goal" class="card space-y-3" aria-labelledby="goal-title">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h2 id="goal-title" class="text-2xl">{gettext("Today's goal")}</h2>
              <.link
                navigate={~p"/settings/learning"}
                class="link inline-flex min-h-6 items-center text-sm"
                id="change-goal"
              >
                {gettext("Change my goal")}
              </.link>
            </div>
            <%= case @dashboard do %>
              <% %{"week" => [_ | _] = week} -> %>
                <.daily_goal xp={List.last(week)["xp"] || 0} goal={@preferences["daily_xp_goal"]} />
              <% _ -> %>
                <.unavailable>{gettext("Today's progress can't be loaded right now.")}</.unavailable>
            <% end %>
          </section>

          <div class="grid gap-6 lg:grid-cols-3">
            <section
              id="daily-quests"
              class="card space-y-4 lg:col-span-2"
              aria-labelledby="quests-title"
            >
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <h2 id="quests-title" class="text-2xl">{gettext("Daily quests")}</h2>
                <p class="text-sm text-muted">
                  {gettext("New quests every day at %{time}.", time: quests_reset_time())}
                </p>
              </div>
              <%= case @dashboard do %>
                <% %{"quests" => [_ | _] = quests} -> %>
                  <.quest_list quests={quests} />
                <% %{"quests" => []} -> %>
                  <p class="text-sm text-muted">{gettext("No quests today.")}</p>
                <% _ -> %>
                  <.unavailable>{gettext("Daily quests can't be loaded right now.")}</.unavailable>
              <% end %>
            </section>

            <section id="badges" class="card space-y-4" aria-labelledby="badges-title">
              <h2 id="badges-title" class="text-2xl">{gettext("Badges")}</h2>
              <%= case @dashboard do %>
                <% %{"equipped_badges" => equipped, "badges_earned" => earned} -> %>
                  <p class="text-sm text-muted">
                    {gettext("%{earned} of %{total} badges earned",
                      earned: earned,
                      total: @dashboard["badges_total"] || earned
                    )}
                  </p>
                  <.equipped_badges :if={equipped != []} id="dashboard-equipped" badges={equipped} />
                  <p :if={equipped == []} class="text-sm text-muted">
                    {gettext("No badge equipped yet.")}
                  </p>
                <% _ -> %>
                  <.unavailable>{gettext("Your badges can't be loaded right now.")}</.unavailable>
              <% end %>
              <.link navigate={~p"/achievements"} class="link text-sm" id="achievements-link">
                {gettext("View all achievements")} →
              </.link>
            </section>
          </div>

          <div class="grid gap-6 lg:grid-cols-3">
            <section
              id="activity"
              class="card space-y-4 lg:col-span-2"
              aria-labelledby="activity-title"
            >
              <h2 id="activity-title" class="text-2xl">{gettext("Last 7 days")}</h2>
              <%= if @dashboard == :unavailable do %>
                <.unavailable>{gettext("Your activity can't be loaded right now.")}</.unavailable>
              <% else %>
                <.week_chart id="week-chart" week={@dashboard["week"] || []} />
              <% end %>
            </section>

            <div class="grid content-start gap-6 sm:grid-cols-2 lg:grid-cols-1">
              <section id="streak" class="card space-y-2" aria-labelledby="streak-title">
                <h2 id="streak-title" class="text-2xl">{gettext("Streak")}</h2>
                <%= cond do %>
                  <% @dashboard == :unavailable -> %>
                    <.unavailable>{gettext("Your streak can't be loaded right now.")}</.unavailable>
                  <% (@dashboard["streak"] || 0) > 0 -> %>
                    <p class="flex items-center gap-2 font-display text-3xl text-ink">
                      <.icon name="hero-fire" class="size-7 text-reward" />
                      {ngettext("%{count}-day streak", "%{count}-day streak", @dashboard["streak"])}
                    </p>
                    <p class="text-sm text-muted">
                      {gettext("Complete a lesson today to keep it going.")}
                    </p>
                  <% true -> %>
                    <p class="text-muted">
                      {gettext("No streak yet — complete a lesson today to start one.")}
                    </p>
                <% end %>
              </section>

              <section id="plan" class="card space-y-3" aria-labelledby="plan-title">
                <h2 id="plan-title" class="text-2xl">{gettext("Membership")}</h2>
                <%= case @billing do %>
                  <% :unavailable -> %>
                    <.unavailable>{gettext("Your plan can't be loaded right now.")}</.unavailable>
                  <% %{"entitlements" => ent} -> %>
                    <p class="flex flex-wrap items-center gap-2">
                      <span class="font-display text-3xl text-ink">{plan_label(ent["plan"])}</span>
                      <.tag
                        :if={ent["plan"] != "free"}
                        kind={if ent["status"] == "active", do: "success", else: "danger"}
                      >
                        {subscription_status_label(ent["status"])}
                      </.tag>
                    </p>
                    <.link navigate={~p"/membership"} class="link text-sm">{gettext(
                      "Manage membership"
                    )} →</.link>
                <% end %>
              </section>
            </div>
          </div>

          <section id="friend-requests" class="card space-y-4" aria-labelledby="requests-title">
            <h2 id="requests-title" class="text-2xl">{gettext("Friend requests")}</h2>
            <%= case @requests do %>
              <% :unavailable -> %>
                <.unavailable>{gettext("Friend requests can't be loaded right now.")}</.unavailable>
              <% %{"incoming" => []} -> %>
                <p class="text-sm text-muted">{gettext("No pending requests.")}</p>
                <.link navigate={~p"/friends"} class="link text-sm">{gettext("Find friends")} →</.link>
              <% %{"incoming" => incoming} -> %>
                <ul class="grid gap-x-8 gap-y-4 md:grid-cols-2 xl:grid-cols-3">
                  <li
                    :for={request <- incoming}
                    id={"request-#{request["id"]}"}
                    class="flex flex-wrap items-center gap-3"
                  >
                    <.avatar user={request["from"]} />
                    <div class="min-w-40 flex-1">
                      <p class="truncate font-medium">{request["from"]["display_name"]}</p>
                      <p class="truncate text-xs text-muted">@{request["from"]["username"]}</p>
                    </div>
                    <div class="flex gap-2">
                      <.button phx-click="accept" phx-value-id={request["id"]}>{gettext("Accept")}</.button>
                      <.button phx-click="decline" phx-value-id={request["id"]} variant="ghost">
                        {gettext("Decline")}
                      </.button>
                    </div>
                  </li>
                </ul>
            <% end %>
          </section>

          <section id="recommendations" class="space-y-4" aria-labelledby="reco-title">
            <div class="space-y-1">
              <h2 id="reco-title" class="text-2xl">{gettext("Recommended for you")}</h2>
              <p
                :if={(@current_user["interests"] || []) != []}
                id="reco-interests"
                class="text-sm text-muted"
              >
                {gettext("Your interests come first: %{interests}.",
                  interests: Enum.map_join(@current_user["interests"], ", ", &interest_label/1)
                )}
                <.link navigate={~p"/settings/profile"} class="link">{gettext("Edit")}</.link>
              </p>
            </div>
            <%= case @dashboard do %>
              <% :unavailable -> %>
                <.unavailable>{gettext("Recommendations can't be loaded right now.")}</.unavailable>
              <% %{"recommendations" => [_ | _] = adventures} -> %>
                <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
                  <.adventure_card :for={a <- adventures} id={"reco-#{a["slug"]}"} adventure={a} />
                </div>
              <% _ -> %>
                <p class="text-sm text-muted">
                  {gettext("You've explored everything we would suggest. Impressive!")}
                </p>
            <% end %>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
