defmodule MysticWeb.Multiplayer.IndexLive do
  @moduledoc "Multiplayer home: open activities, the member's lobbies, invitations and the creation form."
  use MysticWeb, :live_view
  import MysticWeb.MultiplayerComponents

  @form_fields [:title, :max_players, :visibility, :starts_at]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Multiplayer"), page: 1, form: lobby_form(%{}))
     |> load_open()
     |> load_mine()
     |> load_invites()}
  end

  defp load_open(socket) do
    case Api.get(socket, :multiplayer, "/api/lobbies", params: [page: socket.assigns.page]) do
      {:ok, %{"entries" => entries} = page} ->
        assign(socket, open: entries, total_pages: page["total_pages"] || 1)

      _ ->
        assign(socket, open: :unavailable, total_pages: 1)
    end
  end

  defp load_mine(socket) do
    case Api.get(socket, :multiplayer, "/api/me/lobbies") do
      {:ok, %{"lobbies" => lobbies}} -> assign(socket, mine: lobbies)
      _ -> assign(socket, mine: :unavailable)
    end
  end

  defp load_invites(socket) do
    case Api.get(socket, :multiplayer, "/api/me/invites") do
      {:ok, %{"invites" => invites}} -> assign(socket, invites: invites)
      _ -> assign(socket, invites: :unavailable)
    end
  end

  @impl true
  def handle_info({:lobby_invite, _invite}, socket), do: {:noreply, load_invites(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"lobby" => params}, socket),
    do: {:noreply, assign(socket, form: lobby_form(params))}

  def handle_event("create", %{"lobby" => params}, socket) do
    with {:ok, body} <- lobby_body(params),
         {:ok, %{"lobby" => %{"id" => id}}} <-
           Api.post(socket, :multiplayer, "/api/lobbies", json: body) do
      {:noreply, push_navigate(socket, to: ~p"/multiplayer/lobbies/#{id}")}
    else
      {:invalid, errors} ->
        {:noreply, assign(socket, form: lobby_form(params, errors))}

      {:error, {:http, 422, _}} = error ->
        {:noreply, assign(socket, form: lobby_form(params, Api.form_errors(error, @form_fields)))}

      error ->
        {:noreply, put_flash(socket, :error, error_text(error))}
    end
  end

  def handle_event("accept", %{"id" => id}, socket) do
    case Api.post(socket, :multiplayer, "/api/invites/:id/accept", path_params: [id: id]) do
      {:ok, %{"lobby_id" => lobby_id}} ->
        {:noreply, push_navigate(socket, to: ~p"/multiplayer/lobbies/#{lobby_id}")}

      error ->
        {:noreply, socket |> put_flash(:error, error_text(error)) |> load_invites()}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    socket =
      case Api.post(socket, :multiplayer, "/api/invites/:id/decline", path_params: [id: id]) do
        {:ok, _} -> put_flash(socket, :info, gettext("Invitation declined."))
        error -> put_flash(socket, :error, error_text(error))
      end

    {:noreply, load_invites(socket)}
  end

  def handle_event("page", %{"page" => page}, socket) do
    page = (integer(page) || 1) |> max(1) |> min(socket.assigns.total_pages)
    {:noreply, socket |> assign(page: page) |> load_open()}
  end

  def handle_event("refresh", _params, socket),
    do: {:noreply, socket |> load_open() |> load_mine() |> load_invites()}

  defp lobby_form(params, errors \\ []) do
    defaults = %{
      "title" => "",
      "max_players" => "4",
      "visibility" => "open",
      "requires_approval" => "false",
      "starts_at" => ""
    }

    to_form(Map.merge(defaults, params), as: :lobby, errors: errors)
  end

  # The `datetime-local` field is read in the member's time zone (the label says which) and sent in UTC.
  defp lobby_body(params) do
    with {:ok, starts_at} <- starts_at(params["starts_at"]) do
      {:ok,
       %{
         title: String.trim(params["title"] || ""),
         max_players: integer(params["max_players"]),
         visibility: params["visibility"],
         requires_approval: params["requires_approval"] == "true",
         starts_at: starts_at
       }}
    end
  end

  defp starts_at(value) when value in [nil, ""], do: {:ok, nil}

  defp starts_at(value) do
    case from_local_input(value) do
      {:ok, utc} -> {:ok, utc}
      :error -> {:invalid, [starts_at: {gettext("is not a valid date and time"), []}]}
    end
  end

  defp integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
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
      active={:multiplayer}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Multiplayer")} title={gettext("The Rune Relay")}>
          {gettext(
            "A cooperative puzzle for 2 to 4 players. Each of you gets private clues: share them in the chat to find the secret sequence of five runes together."
          )}
        </.page_header>

        <div class="mp-columns">
          <div class="min-w-0 space-y-8">
            <section id="mp-invites" class="card space-y-4" aria-labelledby="invites-title">
              <h2 id="invites-title" class="text-2xl">{gettext("My invitations")}</h2>
              <%= case @invites do %>
                <% :unavailable -> %>
                  <.unavailable>{gettext("Invitations can't be loaded right now.")}</.unavailable>
                <% [] -> %>
                  <p class="text-sm text-muted">
                    {gettext("No pending invitation. Friends can invite you to their activities.")}
                  </p>
                <% invites -> %>
                  <ul class="divide-y divide-line">
                    <li :for={invite <- invites} id={"invite-#{invite["id"]}"} class="member-row">
                      <div class="min-w-0 flex-1">
                        <p class="font-medium text-ink break-words">{invite["lobby"]["title"]}</p>
                        <p class="text-xs text-muted">
                          {gettext("Invited by %{name}", name: display_name(invite["inviter"]))} · {gettext(
                            "%{count} of %{max} players",
                            count: invite["lobby"]["member_count"],
                            max: invite["lobby"]["max_players"]
                          )}
                        </p>
                      </div>
                      <div class="flex flex-wrap gap-2">
                        <.button
                          id={"accept-#{invite["id"]}"}
                          phx-click="accept"
                          phx-value-id={invite["id"]}
                        >
                          {gettext("Join")}
                        </.button>
                        <.button
                          id={"decline-#{invite["id"]}"}
                          phx-click="decline"
                          phx-value-id={invite["id"]}
                          variant="ghost"
                        >
                          {gettext("Decline")}
                        </.button>
                      </div>
                    </li>
                  </ul>
              <% end %>
            </section>

            <section id="mp-mine" class="space-y-4" aria-labelledby="mine-title">
              <h2 id="mine-title" class="text-2xl">{gettext("My activities")}</h2>
              <%= case @mine do %>
                <% :unavailable -> %>
                  <.unavailable>{gettext("Your activities can't be loaded right now.")}</.unavailable>
                <% [] -> %>
                  <p class="text-sm text-muted">
                    {gettext("You are not in any activity yet: join an open one or create yours.")}
                  </p>
                <% lobbies -> %>
                  <div class="grid gap-4 md:grid-cols-2">
                    <.lobby_card :for={lobby <- lobbies} id={"mine-#{lobby["id"]}"} lobby={lobby} />
                  </div>
              <% end %>
            </section>

            <section id="mp-open" class="space-y-4" aria-labelledby="open-title">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 id="open-title" class="text-2xl">{gettext("Open activities")}</h2>
                <.button id="refresh-open" phx-click="refresh" variant="ghost">
                  <.icon name="hero-arrow-path" /> {gettext("Refresh")}
                </.button>
              </div>
              <%= case @open do %>
                <% :unavailable -> %>
                  <.unavailable id="open-unavailable">
                    {gettext("Open activities can't be loaded right now.")}
                  </.unavailable>
                <% [] -> %>
                  <.empty_state icon="hero-puzzle-piece" title={gettext("No open activity")}>
                    {gettext("Be the first: create an activity and invite your friends.")}
                  </.empty_state>
                <% lobbies -> %>
                  <div class="grid gap-4 md:grid-cols-2">
                    <.lobby_card :for={lobby <- lobbies} id={"open-#{lobby["id"]}"} lobby={lobby} />
                  </div>
                  <nav
                    :if={@total_pages > 1}
                    class="flex items-center justify-between gap-2"
                    aria-label={gettext("Pages")}
                  >
                    <.button
                      id="page-prev"
                      phx-click="page"
                      phx-value-page={@page - 1}
                      variant="secondary"
                      disabled={@page <= 1}
                    >
                      {gettext("Previous")}
                    </.button>
                    <span class="text-sm text-muted">
                      {gettext("Page %{page} of %{total}", page: @page, total: @total_pages)}
                    </span>
                    <.button
                      id="page-next"
                      phx-click="page"
                      phx-value-page={@page + 1}
                      variant="secondary"
                      disabled={@page >= @total_pages}
                    >
                      {gettext("Next")}
                    </.button>
                  </nav>
              <% end %>
            </section>
          </div>

          <section id="mp-create" class="card space-y-4 self-start" aria-labelledby="create-title">
            <h2 id="create-title" class="text-2xl">{gettext("Create an activity")}</h2>
            <.form
              for={@form}
              id="create-lobby"
              phx-change="validate"
              phx-submit="create"
              class="space-y-4"
            >
              <.input field={@form[:title]} label={gettext("Title")} maxlength="60" required />
              <.input
                field={@form[:max_players]}
                type="select"
                label={gettext("Players")}
                options={[{"2", "2"}, {"3", "3"}, {"4", "4"}]}
              />
              <fieldset class="space-y-2">
                <legend class="label">{gettext("Visibility")}</legend>
                <label class="choice">
                  <input
                    type="radio"
                    name="lobby[visibility]"
                    value="open"
                    checked={@form[:visibility].value == "open"}
                  />
                  <span>
                    <span class="block font-medium">{gettext("Open")}</span>
                    <span class="block text-xs text-muted">
                      {gettext("Listed: any member can find it.")}
                    </span>
                  </span>
                </label>
                <label class="choice">
                  <input
                    type="radio"
                    name="lobby[visibility]"
                    value="private"
                    checked={@form[:visibility].value == "private"}
                  />
                  <span>
                    <span class="block font-medium">{gettext("Private")}</span>
                    <span class="block text-xs text-muted">
                      {gettext("Only with your invitation or an invitation link.")}
                    </span>
                  </span>
                </label>
              </fieldset>
              <label class="choice" for="lobby_requires_approval">
                <input type="hidden" name="lobby[requires_approval]" value="false" />
                <input
                  type="checkbox"
                  id="lobby_requires_approval"
                  name="lobby[requires_approval]"
                  value="true"
                  checked={@form[:requires_approval].value == "true"}
                />
                <span>{gettext("I approve each request to join")}</span>
              </label>
              <.input
                field={@form[:starts_at]}
                type="datetime-local"
                label={gettext("Scheduled start (%{zone}, optional)", zone: time_zone())}
                hint={gettext("Leave empty to start whenever you are ready.")}
              />
              <.button
                type="submit"
                id="create-submit"
                class="w-full"
                phx-disable-with={gettext("Creating…")}
              >
                <.icon name="hero-sparkles" /> {gettext("Create")}
              </.button>
            </.form>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
