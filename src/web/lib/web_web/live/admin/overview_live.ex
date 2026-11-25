defmodule MysticWeb.Admin.OverviewLive do
  @moduledoc """
  Staff overview with the real indicators of each service; no number is ever made up.
  """
  use MysticWeb, :live_view
  import MysticWeb.AdminComponents
  alias MysticWeb.Admin.Guard

  on_mount {Guard, :staff}

  @services [:accounts, :learning, :billing, :social, :community, :multiplayer, :studio]

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: gettext("Administration")) |> load()}

  defp load(socket) do
    user = socket.assigns.current_user

    stats =
      @services
      |> Enum.reject(&(&1 == :billing and not Guard.admin?(user)))
      |> Task.async_stream(&{&1, fetch(user, &1)}, timeout: 10_000, on_timeout: :kill_task)
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _} -> []
      end)
      |> Map.new()

    assign(socket, stats: stats)
  end

  defp fetch(user, service) do
    case Api.get(user, service, "/api/admin/stats") do
      {:ok, %{"stats" => %{} = stats}} -> stats
      _ -> :unavailable
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # value of a metric: a figure, or why there is none
  defp value(stats, service, path, format \\ & &1) do
    case stats[service] do
      nil ->
        if service == :billing, do: :admins_only, else: :unavailable

      :unavailable ->
        :unavailable

      data ->
        case get_in(data, path) do
          nil -> :unavailable
          v -> format.(v)
        end
    end
  end

  defp tiles do
    [
      {:accounts, gettext("Members"),
       [
         {gettext("Members"), ["members"]},
         {gettext("New in the last 7 days"), ["new_7d"]},
         {gettext("Confirmed email"), ["confirmed"]},
         {gettext("Currently restricted"), ["restricted"]},
         {gettext("Open appeals"), ["open_appeals"]},
         {gettext("Open incidents"), ["open_incidents"]}
       ]},
      {:learning, gettext("Learning"),
       [
         {gettext("Enrollments"), ["enrollments"]},
         {gettext("Lessons completed (7 days)"), ["lessons_completed_7d"]},
         {gettext("XP awarded (7 days)"), ["xp_7d"]}
       ]},
      {:social, gettext("Messages"),
       [
         {gettext("Messages sent (7 days)"), ["messages_7d"]},
         {gettext("Open reports"), ["open_reports"]}
       ]},
      {:community, gettext("Forum"),
       [
         {gettext("Discussions (7 days)"), ["discussions_7d"]},
         {gettext("Replies (7 days)"), ["replies_7d"]},
         {gettext("Open reports"), ["open_reports"]}
       ]},
      {:multiplayer, gettext("Multiplayer"),
       [
         {gettext("Open lobbies"), ["open_lobbies"]},
         {gettext("Matches (7 days)"), ["matches_7d"]}
       ]},
      {:studio, gettext("Studio"),
       [
         {gettext("Projects waiting for review"), ["review_queue"]},
         {gettext("Failed AI generations (24 h)"), ["failed_generations_24h"]}
       ]}
    ]
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, tiles: tiles())

    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      notifications={@notifications}
      active={:overview}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Administration")} title={gettext("Overview")}>
          {gettext(
            "Figures counted by each service right now. Nothing here is estimated: what isn't measured says so."
          )}
          <:actions>
            <.button phx-click="refresh" variant="secondary" id="refresh-stats">
              <.icon name="hero-arrow-path" /> {gettext("Refresh")}
            </.button>
          </:actions>
        </.page_header>

        <div class="metric-grid">
          <section
            :for={{service, title, metrics} <- @tiles}
            id={"tile-#{service}"}
            class="card space-y-4"
            aria-labelledby={"tile-#{service}-title"}
          >
            <h2 id={"tile-#{service}-title"} class="text-2xl">{title}</h2>
            <.unavailable :if={@stats[service] == :unavailable} id={"tile-#{service}-unavailable"}>
              {gettext("This service didn't answer.")}
            </.unavailable>
            <dl :if={@stats[service] != :unavailable} class="metric-list">
              <.metric
                :for={{{label, path}, i} <- Enum.with_index(metrics)}
                id={"metric-#{service}-#{i}"}
                label={label}
                value={value(@stats, service, path)}
              />
            </dl>
          </section>

          <section id="tile-billing" class="card space-y-4" aria-labelledby="tile-billing-title">
            <h2 id="tile-billing-title" class="text-2xl">{gettext("Subscriptions")}</h2>
            <.unavailable :if={@stats[:billing] == :unavailable} id="tile-billing-unavailable">
              {gettext("This service didn't answer.")}
            </.unavailable>
            <dl :if={@stats[:billing] != :unavailable} class="metric-list">
              <.metric
                id="metric-billing-premium"
                label={gettext("Active Premium subscriptions")}
                value={value(@stats, :billing, ["active_subscriptions", "premium"])}
              />
              <.metric
                id="metric-billing-vip"
                label={gettext("Active VIP subscriptions")}
                value={value(@stats, :billing, ["active_subscriptions", "vip"])}
              />
              <.metric
                id="metric-billing-past-due"
                label={gettext("Payment past due (grace period)")}
                value={value(@stats, :billing, ["past_due_subscriptions"])}
              />
              <.metric
                id="metric-billing-revenue"
                label={gettext("Revenue this month (paid invoices)")}
                value={
                  value(
                    @stats,
                    :billing,
                    ["revenue_month_cents"],
                    &money(&1, get_in(@stats, [:billing, "currency"]))
                  )
                }
              />
              <.metric
                id="metric-billing-webhooks"
                label={gettext("Failed webhook events")}
                value={value(@stats, :billing, ["failed_webhook_events"])}
              />
            </dl>
          </section>

          <section id="tile-platform" class="card space-y-4" aria-labelledby="tile-platform-title">
            <h2 id="tile-platform-title" class="text-2xl">{gettext("Platform health")}</h2>
            <dl class="metric-list">
              <.metric
                id="metric-latency"
                label={gettext("Response time (p95)")}
                value={:not_measured}
              />
              <.metric
                id="metric-uptime"
                label={gettext("Availability (uptime)")}
                value={:not_measured}
              />
            </dl>
            <p class="text-sm text-muted">
              {gettext("No monitoring collects these measurements in this MVP.")}
            </p>
          </section>
        </div>
      </div>
    </Layouts.admin>
    """
  end
end
