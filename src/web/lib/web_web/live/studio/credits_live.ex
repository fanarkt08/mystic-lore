defmodule MysticWeb.Studio.CreditsLive do
  @moduledoc "AI credits of the month, their ledger and the member's generations."
  use MysticWeb, :live_view
  import MysticWeb.StudioComponents

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("AI credits"))}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(page: page(params["page"]), history_page: page(params["history"]))
     |> load_credits()
     |> load_history()}
  end

  defp page(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp load_credits(socket) do
    case Api.get(socket, :billing, "/api/me/credits", params: [page: socket.assigns.page]) do
      {:ok, %{"balance" => _} = credits} -> assign(socket, credits: credits)
      _ -> assign(socket, credits: :unavailable)
    end
  end

  defp load_history(socket) do
    case Api.get(socket, :studio, "/api/me/generations",
           params: [page: socket.assigns.history_page]
         ) do
      {:ok, %{"entries" => _} = history} -> assign(socket, history: history)
      _ -> assign(socket, history: :unavailable)
    end
  end

  @impl true
  def handle_info({:credits_changed, _user_id, _balance}, socket),
    do: {:noreply, socket |> load_credits() |> load_history()}

  def handle_info({:entitlements_changed, _user_id, _plan}, socket),
    do: {:noreply, load_credits(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp plan_name("premium"), do: gettext("Premium")
  defp plan_name("vip"), do: gettext("VIP")
  defp plan_name(_), do: gettext("Free")

  defp signed(delta) when delta > 0, do: "+#{delta}"
  defp signed(delta), do: to_string(delta)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:studio}
    >
      <div class="space-y-8">
        <.link navigate={~p"/studio"} class="link text-sm">← {gettext("Studio")}</.link>
        <.page_header eyebrow={gettext("Studio")} title={gettext("AI credits")}>
          {gettext(
            "Each month you get credits according to your plan (Free 20, Premium 300, VIP 1,000). Unused credits expire at the end of the month (UTC)."
          )}
        </.page_header>

        <%= case @credits do %>
          <% :unavailable -> %>
            <.unavailable id="credits-unavailable">
              {gettext("Your credits can't be loaded right now.")}
            </.unavailable>
          <% credits -> %>
            <section class="card studio-credits" id="credits-summary" aria-labelledby="balance-title">
              <h2 id="balance-title" class="sr-only">{gettext("Balance")}</h2>
              <p class="font-display text-5xl text-ink" id="credit-balance">{credits["balance"]}</p>
              <p class="text-muted">
                {gettext("credits left of %{allocation} this month (%{plan} plan)",
                  allocation: credits["allocation"],
                  plan: plan_name(credits["plan"])
                )}
              </p>
              <p :if={credits["reserved"] > 0} class="text-sm text-muted" id="credits-reserved">
                {ngettext(
                  "%{count} credit held by a generation in progress",
                  "%{count} credits held by generations in progress",
                  credits["reserved"]
                )}
              </p>
              <p class="text-sm text-muted">
                {gettext("Renews on %{date}.", date: date(credits["resets_at"]))}
              </p>
              <.link :if={credits["plan"] != "vip"} navigate={~p"/membership"} class="link text-sm">{gettext(
                "More credits with a higher plan"
              )}</.link>
            </section>

            <section class="space-y-4" aria-labelledby="ledger-title">
              <h2 id="ledger-title" class="text-3xl">{gettext("Credit history")}</h2>
              <div :if={credits["entries"] != []} class="table-wrap">
                <table class="data-table" id="credit-ledger">
                  <thead>
                    <tr>
                      <th scope="col">{gettext("Date")}</th>
                      <th scope="col">{gettext("Operation")}</th>
                      <th scope="col">{gettext("Credits")}</th>
                      <th scope="col">{gettext("Balance")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- credits["entries"]} id={"entry-#{entry["id"]}"}>
                      <td data-label={gettext("Date")}>
                        {datetime(entry["inserted_at"])}
                      </td>
                      <td data-label={gettext("Operation")}>
                        {entry_label(entry["kind"])}
                        <span :if={entry["reason"]} class="text-muted">· {generation_label(
                          entry["reason"]
                        )}</span>
                      </td>
                      <td data-label={gettext("Credits")} class="tabular-nums">
                        {if entry["kind"] == "consumption",
                          do: entry["amount"],
                          else: signed(entry["delta"])}
                      </td>
                      <td data-label={gettext("Balance")} class="tabular-nums">
                        {entry["balance_after"]}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p :if={credits["entries"] == []} class="text-muted">{gettext("No operation yet.")}</p>
              <.pager
                id="ledger-pager"
                page={credits["page"]}
                total_pages={credits["total_pages"]}
                param="page"
                other={%{"history" => @history_page}}
              />
            </section>
        <% end %>

        <section class="space-y-4" aria-labelledby="history-title">
          <h2 id="history-title" class="text-3xl">{gettext("My AI generations")}</h2>
          <%= case @history do %>
            <% :unavailable -> %>
              <.unavailable>{gettext("Your generations can't be loaded right now.")}</.unavailable>
            <% %{"entries" => []} -> %>
              <p class="text-muted">{gettext("No generation yet.")}</p>
            <% history -> %>
              <div class="table-wrap">
                <table class="data-table" id="generation-history">
                  <thead>
                    <tr>
                      <th scope="col">{gettext("Date")}</th>
                      <th scope="col">{gettext("Project")}</th>
                      <th scope="col">{gettext("Type")}</th>
                      <th scope="col">{gettext("Credits")}</th>
                      <th scope="col">{gettext("Status")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={g <- history["entries"]} id={"history-#{g["id"]}"}>
                      <td data-label={gettext("Date")}>{date(g["inserted_at"])}</td>
                      <td data-label={gettext("Project")}>
                        <.link navigate={~p"/studio/#{g["project_id"]}"} class="link">{g[
                          "project_title"
                        ]}</.link>
                      </td>
                      <td data-label={gettext("Type")}>{generation_label(g["kind"])}</td>
                      <td data-label={gettext("Credits")} class="tabular-nums">
                        {g["cost"]} · {credits_state(g["credits"])}
                      </td>
                      <td data-label={gettext("Status")}>{generation_status(g["status"])}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <.pager
                id="history-pager"
                page={history["page"]}
                total_pages={history["total_pages"]}
                param="history"
                other={%{"page" => @page}}
              />
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :param, :string, required: true
  attr :other, :map, required: true

  defp pager(assigns) do
    ~H"""
    <nav :if={@total_pages > 1} id={@id} class="flex items-center gap-3" aria-label={gettext("Pages")}>
      <.link
        :if={@page > 1}
        patch={"/studio/credits?" <> URI.encode_query(Map.put(@other, @param, @page - 1))}
        class="link"
      >{gettext("Previous")}</.link>
      <span class="text-sm text-muted">{gettext("Page %{page} of %{total}",
        page: @page,
        total: @total_pages
      )}</span>
      <.link
        :if={@page < @total_pages}
        patch={"/studio/credits?" <> URI.encode_query(Map.put(@other, @param, @page + 1))}
        class="link"
      >{gettext("Next")}</.link>
    </nav>
    """
  end
end
