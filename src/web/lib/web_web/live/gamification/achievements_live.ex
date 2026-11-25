defmodule MysticWeb.Gamification.AchievementsLive do
  @moduledoc """
  Member achievements and equipped badges. learning alone enforces the equip rules.
  """
  use MysticWeb, :live_view
  import MysticWeb.GamificationComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Achievements"), status: nil, error: nil)
     |> load()}
  end

  defp load(socket) do
    case Api.get(socket, :learning, "/api/me/achievements") do
      {:ok, %{"badges" => _} = body} -> put_state(socket, body)
      _ -> assign(socket, badges: :unavailable, equipped: [], max: 3)
    end
  end

  defp put_state(socket, body),
    do:
      assign(socket,
        badges: body["badges"],
        equipped: body["equipped"] || [],
        max: body["max_equipped"] || 3
      )

  @impl true
  def handle_event("equip", %{"id" => id}, socket),
    do: {:noreply, save(socket, equipped_ids(socket) ++ [id], id, :equipped)}

  def handle_event("unequip", %{"id" => id}, socket),
    do: {:noreply, save(socket, equipped_ids(socket) -- [id], id, :unequipped)}

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) do
    ids = equipped_ids(socket)
    from = Enum.find_index(ids, &(&1 == id))
    to = from && if(dir == "up", do: from - 1, else: from + 1)

    if (from && to >= 0) and to < length(ids),
      do: {:noreply, save(socket, swap(ids, from, to), id, :moved)},
      else: {:noreply, socket}
  end

  defp equipped_ids(socket), do: Enum.map(socket.assigns.equipped, & &1["id"])

  defp swap(list, i, j),
    do: list |> List.replace_at(i, Enum.at(list, j)) |> List.replace_at(j, Enum.at(list, i))

  defp save(socket, ids, id, action) do
    case Api.put(socket, :learning, "/api/me/badges/equipped", json: %{badge_ids: ids}) do
      {:ok, %{"badges" => _} = body} ->
        socket |> put_state(body) |> assign(status: announcement(action, body, id), error: nil)

      result ->
        # learning reste la référence : l'état affiché est rechargé (un autre onglet a pu le changer).
        socket |> assign(status: nil, error: error_message(result)) |> load_if_available()
    end
  end

  defp load_if_available(socket) do
    case Api.get(socket, :learning, "/api/me/achievements") do
      {:ok, %{"badges" => _} = body} -> put_state(socket, body)
      _ -> socket
    end
  end

  defp announcement(action, body, id) do
    badge = Enum.find(body["badges"], &(&1["id"] == id)) || %{}
    name = badge["name"] || gettext("The badge")

    case action do
      :equipped ->
        gettext("%{name} equipped in slot %{position}.", name: name, position: badge["position"])

      :moved ->
        gettext("%{name} moved to slot %{position}.", name: name, position: badge["position"])

      :unequipped ->
        gettext("%{name} unequipped.", name: name)
    end
  end

  defp error_message(result) do
    case Api.error_code(result) do
      "equip_limit_exceeded" ->
        gettext("You can equip up to 3 badges. Unequip one first, then try again.")

      "badge_not_earned" ->
        gettext("You can only equip badges you have earned.")

      _ ->
        Api.error_message(result)
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
      active={:achievements}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Hall of badges")} title={gettext("Achievements")}>
          {gettext("Earn badges as you learn, then equip up to three to show on your public profile.")}
          <:actions>
            <.button navigate={~p"/members/#{@current_user["username"]}"} variant="secondary">
              <.icon name="hero-user-circle" /> {gettext("View my profile")}
            </.button>
          </:actions>
        </.page_header>

        <%= if @badges == :unavailable do %>
          <.unavailable id="achievements-unavailable">
            {gettext("Your badges can't be loaded right now.")}
          </.unavailable>
        <% else %>
          <p id="equip-status" role="status" class="equip-status">
            <.icon :if={@status} name="hero-check-circle" class="size-5 shrink-0 text-success" />
            <span>{@status}</span>
          </p>
          <div id="equip-error" role="alert">
            <div :if={@error} class="notice notice-danger">
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
              <div class="min-w-0 flex-1 space-y-1">
                <p class="font-semibold text-ink">{gettext("Your badges were not changed")}</p>
                <p>{@error}</p>
              </div>
            </div>
          </div>

          <section id="equipped" class="card space-y-4" aria-labelledby="equipped-title">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h2 id="equipped-title" class="text-2xl">{gettext("Equipped badges")}</h2>
              <p class="text-sm text-muted">
                {gettext("%{count} of %{max} slots used", count: length(@equipped), max: @max)}
              </p>
            </div>
            <p class="text-sm text-muted">
              {gettext("They appear on your public profile in this order.")}
            </p>
            <ol class="equip-slots">
              <.equip_slot
                :for={slot <- 1..@max//1}
                slot={slot}
                badge={Enum.at(@equipped, slot - 1)}
                last={length(@equipped)}
              />
            </ol>
          </section>

          <section id="badges" class="space-y-4" aria-labelledby="badges-title">
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <h2 id="badges-title" class="text-2xl">{gettext("All badges")}</h2>
              <p class="text-sm text-muted">
                {gettext("%{earned} of %{total} earned",
                  earned: Enum.count(@badges, & &1["earned"]),
                  total: length(@badges)
                )}
              </p>
            </div>
            <ul :if={@badges != []} class="achievement-grid">
              <.achievement_card :for={badge <- @badges} badge={badge} />
            </ul>
            <p :if={@badges == []} class="text-sm text-muted">
              {gettext("No badges exist yet.")}
            </p>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :slot, :integer, required: true
  attr :badge, :map, default: nil
  attr :last, :integer, required: true

  # Les boutons ont un id par emplacement : après un déplacement, le focus reste sur le même bouton.
  defp equip_slot(assigns) do
    ~H"""
    <li id={"slot-#{@slot}"} class={["equip-slot", !@badge && "equip-slot-empty"]}>
      <p class="eyebrow">{gettext("Slot %{slot}", slot: @slot)}</p>
      <%= if @badge do %>
        <div class="flex min-w-0 items-center gap-3">
          <.badge_medal badge={@badge} />
          <p class="min-w-0 break-words font-display text-2xl text-ink">{@badge["name"]}</p>
        </div>
        <div class="equip-actions">
          <.button
            id={"slot-#{@slot}-up"}
            variant="secondary"
            phx-click="move"
            phx-value-id={@badge["id"]}
            phx-value-dir="up"
            disabled={@slot == 1}
            aria-label={gettext("Move %{name} up", name: @badge["name"])}
          >
            <.icon name="hero-arrow-up" /> {gettext("Up")}
          </.button>
          <.button
            id={"slot-#{@slot}-down"}
            variant="secondary"
            phx-click="move"
            phx-value-id={@badge["id"]}
            phx-value-dir="down"
            disabled={@slot == @last}
            aria-label={gettext("Move %{name} down", name: @badge["name"])}
          >
            <.icon name="hero-arrow-down" /> {gettext("Down")}
          </.button>
          <.button
            id={"slot-#{@slot}-unequip"}
            variant="ghost"
            phx-click="unequip"
            phx-value-id={@badge["id"]}
            aria-label={gettext("Unequip %{name}", name: @badge["name"])}
          >
            <.icon name="hero-minus-circle" /> {gettext("Unequip")}
          </.button>
        </div>
      <% else %>
        <p class="text-sm text-muted">{gettext("Empty. Equip an earned badge below.")}</p>
      <% end %>
    </li>
    """
  end
end
