defmodule MysticWeb.Multiplayer.LobbyLive do
  @moduledoc """
  A lobby and its game of « The Rune Relay ». The page only sends intentions; the service checks everything.
  """
  use MysticWeb, :live_view
  import MysticWeb.MultiplayerComponents
  alias MysticWeb.Social

  @heartbeat_ms 10_000
  @members ~w(host player)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(id: id, page_title: gettext("Activity"), detail: nil, error: nil, topic: nil)
      |> assign(beating: false, guess: [], announce: "", messages: nil, chat: :ok, friends: nil)
      |> assign(new_link: nil, reporting: nil, chat_form: chat_form(), link_form: link_form())

    {:ok, if(connected?(socket), do: open(socket), else: load(socket))}
  end

  ## Loading

  # Access check first; subscription only on success; then the state is loaded (no change can be missed).
  defp open(socket) do
    case fetch(socket) do
      {:ok, %{"lobby" => _}} ->
        topic = "lobby:#{socket.assigns.id}"
        MlShared.Events.subscribe(topic)
        socket |> assign(topic: topic) |> load()

      error ->
        fail(socket, error)
    end
  end

  defp fetch(socket),
    do: Api.get(socket, :multiplayer, "/api/lobbies/:id", path_params: [id: socket.assigns.id])

  defp load(socket) do
    case fetch(socket) do
      {:ok, %{"lobby" => lobby} = detail} ->
        old = socket.assigns.detail

        socket
        |> assign(detail: detail, error: nil, page_title: lobby["title"])
        |> assign(announce: announcement(old, detail, me(socket)))
        |> reset_guess(old, detail)
        |> member_extras()

      error ->
        fail(socket, error)
    end
  end

  # A member gets heartbeats and the chat; the host also gets their friends (invitations).
  defp member_extras(socket) do
    if connected?(socket) and member?(socket) do
      socket
      |> then(&if(&1.assigns.beating, do: &1, else: start_heartbeat(&1)))
      |> then(&if(&1.assigns.messages == nil, do: load_chat(&1), else: &1))
      |> then(&if(host?(&1) and &1.assigns.friends == nil, do: load_friends(&1), else: &1))
    else
      socket
    end
  end

  defp start_heartbeat(socket) do
    send(self(), :heartbeat)
    assign(socket, beating: true)
  end

  defp fail(socket, error) do
    case {error, socket.assigns.detail} do
      # transient outage while the page is open: keep the last known state
      {{:error, :unavailable}, %{}} ->
        put_flash(socket, :error, Api.error_message(error))

      _ ->
        reason =
          case error do
            {:error, {:http, 404, _}} -> :not_found
            {:error, {:http, 403, %{"error" => "banned"}}} -> :banned
            _ -> :unavailable
          end

        socket |> leave_topic() |> assign(error: reason, detail: nil, beating: false)
    end
  end

  defp leave_topic(%{assigns: %{topic: topic}} = socket) when is_binary(topic) do
    MlShared.Events.unsubscribe(topic)
    assign(socket, topic: nil)
  end

  defp leave_topic(socket), do: socket

  defp load_chat(socket) do
    case Api.get(socket, :multiplayer, "/api/lobbies/:id/messages",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"entries" => entries}} -> assign(socket, messages: entries, chat: :ok)
      _ -> assign(socket, messages: socket.assigns.messages || [], chat: :unavailable)
    end
  end

  defp load_friends(socket) do
    case Api.get(socket, :social, "/api/me/friends") do
      {:ok, %{"friends" => friends}} -> assign(socket, friends: friends)
      _ -> assign(socket, friends: :unavailable)
    end
  end

  ## Real time

  @impl true
  def handle_info({:lobby_changed, id}, %{assigns: %{id: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:chat_posted, id}, %{assigns: %{id: id}} = socket) do
    if member?(socket), do: {:noreply, load_chat(socket)}, else: {:noreply, socket}
  end

  def handle_info(:heartbeat, socket) do
    if member?(socket) and is_nil(socket.assigns.error) do
      Api.post(socket, :multiplayer, "/api/lobbies/:id/heartbeat",
        path_params: [id: socket.assigns.id]
      )

      Process.send_after(self(), :heartbeat, @heartbeat_ms)
      {:noreply, socket}
    else
      {:noreply, assign(socket, beating: false)}
    end
  end

  # A block (or unblock) changes what the chat shows: social says so through `{:friendship_changed, …}`.
  def handle_info({:friendship_changed, _user_id}, socket) do
    socket = if member?(socket), do: load_chat(socket), else: socket
    {:noreply, if(host?(socket), do: load_friends(socket), else: socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Actions (each one is authorized by the multiplayer service)

  @impl true
  def handle_event("join", _params, socket) do
    case lobby_post(socket, "/join") do
      {:ok, %{"status" => "pending"}} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Request sent: the host must approve it.")) |> load()}

      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("You joined the activity.")) |> load()}

      error ->
        {:noreply, put_flash(socket, :error, error_text(error))}
    end
  end

  def handle_event("accept_invite", _params, socket) do
    case invite_post(socket, "accept") do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("You joined the activity.")) |> load()}

      error ->
        {:noreply, socket |> put_flash(:error, error_text(error)) |> load()}
    end
  end

  def handle_event("decline_invite", _params, socket) do
    case invite_post(socket, "decline") do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation declined."))
         |> push_navigate(to: ~p"/multiplayer")}

      error ->
        {:noreply, put_flash(socket, :error, error_text(error))}
    end
  end

  def handle_event("leave", _params, socket) do
    case lobby_post(socket, "/leave") do
      {:ok, _} ->
        {:noreply,
         socket
         |> leave_topic()
         |> put_flash(:info, gettext("You left the activity."))
         |> push_navigate(to: ~p"/multiplayer")}

      error ->
        {:noreply, put_flash(socket, :error, error_text(error))}
    end
  end

  def handle_event("ready", _params, socket),
    do: act(socket, lobby_post(socket, "/ready", %{ready: !my_ready?(socket)}))

  def handle_event("start", _params, socket), do: act(socket, lobby_post(socket, "/start"))

  def handle_event("kick", %{"id" => id}, socket),
    do: act(socket, lobby_post(socket, "/kick", %{user_id: id}), gettext("Player removed."))

  def handle_event("transfer", %{"id" => id}, socket),
    do:
      act(
        socket,
        lobby_post(socket, "/transfer", %{user_id: id}),
        gettext("Host role handed over.")
      )

  def handle_event("approve", %{"id" => id}, socket),
    do: act(socket, request_post(socket, id, "approve"), gettext("Request approved."))

  def handle_event("decline_request", %{"id" => id}, socket),
    do: act(socket, request_post(socket, id, "decline"), gettext("Request declined."))

  def handle_event("invite", %{"id" => id}, socket),
    do: act(socket, lobby_post(socket, "/invites", %{user_id: id}), gettext("Invitation sent."))

  def handle_event("create_link", %{"link" => params}, socket) do
    body = %{
      max_uses: integer(params["max_uses"]),
      expires_in_minutes: integer(params["minutes"])
    }

    case lobby_post(socket, "/links", body) do
      {:ok, %{"link" => %{"token" => token}}} ->
        {:noreply, socket |> assign(new_link: url(~p"/multiplayer/join/#{token}")) |> load()}

      error ->
        {:noreply, put_flash(socket, :error, error_text(error))}
    end
  end

  def handle_event("revoke_link", %{"id" => link_id}, socket) do
    result =
      Api.delete(socket, :multiplayer, "/api/lobbies/:id/links/:link_id",
        path_params: [id: socket.assigns.id, link_id: link_id]
      )

    act(assign(socket, new_link: nil), result, gettext("Link revoked: it can't be used anymore."))
  end

  def handle_event("send", %{"chat" => %{"body" => body}}, socket) do
    body = String.trim(body)

    cond do
      body == "" ->
        {:noreply, assign(socket, chat_form: chat_form(body, gettext("Write a message first.")))}

      String.length(body) > 500 ->
        message = gettext("Messages are limited to 500 characters.")
        {:noreply, assign(socket, chat_form: chat_form(body, message))}

      true ->
        case lobby_post(socket, "/messages", %{body: body}) do
          {:ok, %{"message" => _}} ->
            {:noreply, socket |> assign(chat_form: chat_form()) |> load_chat()}

          error ->
            {:noreply, assign(socket, chat_form: chat_form(body, error_text(error)))}
        end
    end
  end

  def handle_event("pick", %{"rune" => rune}, socket) do
    guess = socket.assigns.guess

    guess =
      case integer(rune) do
        id when id in 0..7 ->
          cond do
            id in guess -> List.delete(guess, id)
            length(guess) < 5 -> guess ++ [id]
            true -> guess
          end

        _ ->
          guess
      end

    {:noreply, assign(socket, guess: guess)}
  end

  def handle_event("undo", _params, socket),
    do: {:noreply, assign(socket, guess: Enum.drop(socket.assigns.guess, -1))}

  def handle_event("clear", _params, socket), do: {:noreply, assign(socket, guess: [])}

  def handle_event("propose", _params, socket) do
    case lobby_post(socket, "/attempts", %{sequence: socket.assigns.guess}) do
      {:ok, _} -> {:noreply, socket |> assign(guess: []) |> load()}
      error -> {:noreply, socket |> put_flash(:error, error_text(error)) |> load()}
    end
  end

  def handle_event("report", %{"id" => id}, socket) do
    user =
      Enum.find_value(socket.assigns.detail["members"], &(&1["user"]["id"] == id && &1["user"]))

    {:noreply, assign(socket, reporting: user)}
  end

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: nil)}

  def handle_event("submit_report", %{"report" => params}, socket) do
    body = %{
      user_id: socket.assigns.reporting["id"],
      reason: params["reason"],
      details: params["details"]
    }

    case lobby_post(socket, "/reports", body) do
      {:ok, _} ->
        message = gettext("Report sent. Thank you — the moderators will review it.")
        {:noreply, socket |> assign(reporting: nil) |> put_flash(:info, message)}

      error ->
        {:noreply, put_flash(socket, :error, error_text(error))}
    end
  end

  def handle_event("block", %{"id" => id}, socket) do
    socket =
      case Social.act(socket, "block", id) do
        {:ok, message} -> put_flash(socket, :info, message)
        {:error, message} -> put_flash(socket, :error, message)
      end

    {:noreply, load_chat(socket)}
  end

  defp act(socket, result, success \\ nil) do
    case result do
      {:ok, _} ->
        {:noreply,
         socket |> then(&if(success, do: put_flash(&1, :info, success), else: &1)) |> load()}

      error ->
        {:noreply, socket |> put_flash(:error, error_text(error)) |> load()}
    end
  end

  defp lobby_post(socket, suffix, body \\ nil) do
    Api.post(
      socket,
      :multiplayer,
      "/api/lobbies/:id" <> suffix,
      [path_params: [id: socket.assigns.id]] ++ if(body, do: [json: body], else: [])
    )
  end

  defp request_post(socket, user_id, verb) do
    Api.post(socket, :multiplayer, "/api/lobbies/:id/requests/:user_id/#{verb}",
      path_params: [id: socket.assigns.id, user_id: user_id]
    )
  end

  defp invite_post(socket, verb) do
    Api.post(socket, :multiplayer, "/api/invites/:id/#{verb}",
      path_params: [id: socket.assigns.detail["my_invite_id"]]
    )
  end

  ## Helpers

  defp me(socket), do: socket.assigns.current_user["id"]
  defp role(socket), do: socket.assigns.detail && socket.assigns.detail["role"]
  defp member?(socket), do: role(socket) in @members
  defp host?(socket), do: role(socket) == "host"

  defp my_ready?(socket) do
    Enum.any?(socket.assigns.detail["members"], &(&1["user"]["id"] == me(socket) and &1["ready"]))
  end

  defp integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp chat_form(body \\ "", error \\ nil),
    do:
      to_form(%{"body" => body}, as: :chat, errors: if(error, do: [body: {error, []}], else: []))

  defp link_form, do: to_form(%{"max_uses" => "5", "minutes" => "60"}, as: :link)

  # A new game, or a finished one, starts a fresh composition.
  defp reset_guess(socket, old, new) do
    old_match = old && old["match"]
    match = new["match"]

    if match && old_match && match["id"] == old_match["id"] && match["status"] == "active",
      do: socket,
      else: assign(socket, guess: [])
  end

  defp names(detail) do
    members = for m <- detail["members"], do: m["user"]
    players = if detail["match"], do: detail["match"]["players"], else: []
    Map.new(members ++ players, &{&1["id"], display_name(&1)})
  end

  # What a screen reader user needs to hear when the game moves on (aria-live region).
  defp announcement(old, new, me) do
    old_match = old && old["match"]
    match = new["match"]
    names = names(new)

    cond do
      is_nil(old) or is_nil(match) ->
        ""

      is_nil(old_match) or old_match["id"] != match["id"] ->
        Enum.join([gettext("The game has started."), turn_text(match, me, names)], " ")

      true ->
        new_attempts = length(match["attempts"]) > length(old_match["attempts"])

        [
          new_attempts && attempt_text(List.last(match["attempts"]), names),
          match["status"] != old_match["status"] && result_text(match),
          (new_attempts or match["current_player"] != old_match["current_player"]) &&
            turn_text(match, me, names)
        ]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.join(" ")
    end
  end

  defp attempt_text(attempt, names) do
    gettext(
      "%{name} proposed %{sequence}: %{hits} in the right place, %{present} in the wrong place.",
      name: Map.get(names, attempt["user_id"], gettext("A player")),
      sequence: sequence_text(attempt["sequence"]),
      hits: attempt["hits"],
      present: attempt["present"]
    )
  end

  defp turn_text(%{"status" => "active", "current_player" => me}, me, _names),
    do: gettext("It's your turn.")

  defp turn_text(%{"status" => "active", "current_player" => id}, _me, names),
    do: gettext("It's %{name}'s turn.", name: Map.get(names, id, gettext("another player")))

  defp turn_text(_match, _me, _names), do: ""

  defp result_text(%{"status" => "won", "secret" => secret}),
    do: gettext("Victory! The sequence was %{sequence}.", sequence: sequence_text(secret))

  defp result_text(%{"status" => "lost", "secret" => secret}),
    do:
      gettext("Defeat: no attempts left. The sequence was %{sequence}.",
        sequence: sequence_text(secret)
      )

  defp result_text(%{"status" => "aborted", "reason" => "abandoned"}),
    do: gettext("The game was interrupted: every player was away for too long.")

  defp result_text(%{"status" => "aborted"}),
    do: gettext("The game was interrupted: fewer than 2 players remained.")

  defp result_text(_match), do: ""

  defp scheduled_later?(%{"starts_at" => at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp scheduled_later?(_lobby), do: false

  ## Rendering

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
      <p id="mp-announce" class="sr-only" role="status" aria-live="polite">{@announce}</p>
      <div class="space-y-6">
        <nav class="breadcrumb" aria-label={gettext("Breadcrumb")}>
          <.link navigate={~p"/multiplayer"}>← {gettext("Multiplayer")}</.link>
        </nav>
        <%= cond do %>
          <% @error == :not_found -> %>
            <.notice id="lobby-not-found" kind="danger" title={gettext("Activity not found")}>
              {gettext("This activity doesn't exist, has ended, or is private.")}
            </.notice>
          <% @error == :banned -> %>
            <.notice id="lobby-banned" kind="danger" title={gettext("You can't access this activity")}>
              {gettext("The host removed you from this activity.")}
            </.notice>
          <% @error == :unavailable -> %>
            <.unavailable id="lobby-unavailable">
              {gettext("This activity can't be loaded right now.")}
            </.unavailable>
          <% @detail == nil -> %>
            <span class="spinner" role="img" aria-label={gettext("Loading")}></span>
          <% true -> %>
            <.room {assigns} me={@current_user["id"]} />
        <% end %>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RuneGrid">
        export default {
          mounted() {
            this.el.addEventListener("keydown", (e) => {
              const columns = getComputedStyle(this.el).gridTemplateColumns.split(" ").length
              const moves = {ArrowRight: 1, ArrowLeft: -1, ArrowDown: columns, ArrowUp: -columns}
              const buttons = [...this.el.querySelectorAll("button")]
              const index = buttons.indexOf(document.activeElement)
              if (!(e.key in moves) || index < 0) return
              e.preventDefault()
              buttons[(index + moves[e.key] + buttons.length) % buttons.length].focus()
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp room(assigns) do
    detail = assigns.detail
    match = detail["match"]

    assigns =
      assign(assigns,
        lobby: detail["lobby"],
        role: detail["role"],
        member?: detail["role"] in @members,
        host?: detail["role"] == "host",
        match: match,
        participant?: match != nil and Enum.any?(match["players"], &(&1["id"] == assigns.me)),
        my_turn?:
          match != nil and match["status"] == "active" and match["current_player"] == assigns.me,
        names: names(detail),
        ready_count: Enum.count(detail["members"], & &1["ready"]),
        my_ready?: Enum.any?(detail["members"], &(&1["user"]["id"] == assigns.me and &1["ready"]))
      )

    ~H"""
    <header id="lobby-header" class="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
      <div class="min-w-0 space-y-2">
        <p class="eyebrow">{gettext("The Rune Relay · cooperative")}</p>
        <h1 id="lobby-title" class="text-4xl md:text-5xl break-words">{@lobby["title"]}</h1>
        <div class="flex flex-wrap gap-2">
          <.tag icon={
            if @lobby["visibility"] == "private", do: "hero-lock-closed", else: "hero-globe-alt"
          }>
            {visibility_label(@lobby["visibility"])}
          </.tag>
          <.tag icon="hero-user-group">
            {gettext("%{count} of %{max} players",
              count: @lobby["member_count"],
              max: @lobby["max_players"]
            )}
          </.tag>
          <.tag :if={@lobby["requires_approval"]} icon="hero-hand-raised">
            {gettext("Host approval")}
          </.tag>
          <.tag :if={@lobby["starts_at"]} kind="premium" icon="hero-calendar" id="lobby-schedule">
            {gettext("Starts %{time}", time: datetime(@lobby["starts_at"]))}
          </.tag>
          <.tag kind="success" id="my-role">{role_label(@role)}</.tag>
        </div>
      </div>
      <div class="flex shrink-0 flex-wrap gap-2">
        <.button :if={@role == "spectator"} id="join-lobby" phx-click="join">
          <.icon name="hero-user-plus" />
          {if @lobby["requires_approval"], do: gettext("Ask to join"), else: gettext("Join")}
        </.button>
        <.button :if={@role == "invited"} id="accept-invite" phx-click="accept_invite">
          <.icon name="hero-check" /> {gettext("Accept the invitation")}
        </.button>
        <.button
          :if={@role == "invited"}
          id="decline-invite"
          phx-click="decline_invite"
          variant="ghost"
        >
          {gettext("Decline")}
        </.button>
        <.button
          :if={@role in ~w(host player pending)}
          id="leave-lobby"
          phx-click="leave"
          variant="danger"
          data-confirm={gettext("Leave this activity?")}
        >
          {if @role == "pending", do: gettext("Cancel my request"), else: gettext("Leave")}
        </.button>
      </div>
    </header>

    <.notice :if={@role == "pending"} id="pending-note" kind="info">
      {gettext("Your request is waiting for the host's approval.")}
    </.notice>

    <Social.report_panel :if={@reporting} user={@reporting} />

    <%!-- Mobile: one column in reading order (game, ready, players, chat, host tools), see multiplayer.css --%>
    <div class="mp-layout">
      <div class="mp-col">
        <.game :if={@match} {assigns} />
        <.ready_check :if={@member? and @lobby["status"] == "waiting"} {assigns} />
        <.host_tools :if={@host?} {assigns} />
      </div>
      <div class="mp-col">
        <.members {assigns} />
        <.chat :if={@member?} {assigns} />
      </div>
    </div>
    """
  end

  defp game(assigns) do
    ~H"""
    <section id="game" class="card space-y-5" aria-labelledby="game-title">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 id="game-title" class="text-3xl">{gettext("The Rune Relay")}</h2>
        <p :if={@match["status"] == "active"} id="attempts-left" class="text-sm text-muted">
          {ngettext("%{count} attempt left", "%{count} attempts left", @match["attempts_left"])}
        </p>
      </div>

      <div id="game-status">
        <%= case @match["status"] do %>
          <% "active" -> %>
            <.notice :if={@my_turn?} kind="reward" title={gettext("It's your turn")}>
              {gettext("Compose a sequence of 5 runes and propose it to the team.")}
            </.notice>
            <.notice :if={!@my_turn?} kind="info">
              {if @participant?,
                do:
                  gettext("Waiting for %{name} to propose a sequence. Share your clues in the chat!",
                    name: Map.get(@names, @match["current_player"], gettext("another player"))
                  ),
                else: gettext("You are watching this game: you will be able to join the next one.")}
            </.notice>
          <% "won" -> %>
            <.notice id="game-won" kind="success" title={gettext("Victory!")}>
              <p>
                {gettext("The secret sequence was %{sequence}.",
                  sequence: sequence_text(@match["secret"])
                )}
              </p>
              <p id="my-reward">{reward_text(@match, @participant?)}</p>
            </.notice>
          <% "lost" -> %>
            <.notice id="game-lost" kind="warning" title={gettext("Defeat")}>
              {gettext("No attempts left. The secret sequence was %{sequence}.",
                sequence: sequence_text(@match["secret"])
              )}
            </.notice>
          <% _ -> %>
            <.notice id="game-aborted" kind="warning" title={gettext("Game interrupted")}>
              {result_text(@match)}
            </.notice>
        <% end %>
      </div>

      <ol id="turn-order" class="mp-turns" aria-label={gettext("Turn order")}>
        <li
          :for={player <- @match["players"]}
          id={"turn-#{player["id"]}"}
          class={["mp-turn", player["id"] == @match["current_player"] && "mp-turn-current"]}
        >
          <span class="min-w-0 truncate">
            {display_name(player)}<span :if={player["id"] == @me}> ({gettext("you")})</span>
          </span>
          <.tag :if={player["id"] == @match["current_player"]} kind="info" icon="hero-play">
            {gettext("Playing now")}
          </.tag>
          <.tag :if={player["id"] in @match["absent"]} icon="hero-signal-slash">
            {gettext("Away: skipped")}
          </.tag>
        </li>
      </ol>

      <section :if={@participant?} id="my-hints" class="mp-hints" aria-labelledby="hints-title">
        <h3 id="hints-title" class="text-xl">{gettext("Your private clues")}</h3>
        <p class="text-sm text-muted">
          {gettext(
            "Only you can see them. Share them in the chat: together they reveal a single sequence."
          )}
        </p>
        <ul class="space-y-1">
          <li :for={hint <- @match["my_hints"]} class="flex gap-2">
            <.icon name="hero-key" class="mt-1 size-4 shrink-0 text-reward" />
            <span>{hint_text(hint)}</span>
          </li>
        </ul>
      </section>

      <div :if={@participant? and @match["status"] == "active"} id="composer" class="space-y-3">
        <h3 id="composer-title" class="text-xl">{gettext("Compose a sequence of 5 runes")}</h3>
        <p class="text-sm text-muted">
          {gettext(
            "Pick the runes in order. Pick a chosen rune again to remove it. Arrow keys move between runes."
          )}
        </p>
        <div
          id="rune-grid"
          class="rune-grid"
          role="group"
          aria-labelledby="composer-title"
          phx-hook=".RuneGrid"
        >
          <button
            :for={rune <- runes()}
            type="button"
            id={"rune-#{rune}"}
            class="rune"
            phx-click="pick"
            phx-value-rune={rune}
            aria-pressed={to_string(rune in @guess)}
          >
            <.rune_face rune={rune} />
            <span :if={rune in @guess} class="rune-slot">
              {gettext("position %{n}", n: Enum.find_index(@guess, &(&1 == rune)) + 1)}
            </span>
          </button>
        </div>
        <p id="current-guess" class="text-sm" aria-live="polite">
          {gettext("Your sequence (%{count} of 5):", count: length(@guess))}
          <span class="font-medium text-ink">
            {if @guess == [], do: gettext("empty"), else: sequence_text(@guess)}
          </span>
        </p>
        <div class="flex flex-wrap gap-2">
          <.button
            id="propose"
            phx-click="propose"
            disabled={length(@guess) != 5 or not @my_turn?}
            phx-disable-with={gettext("Proposing…")}
          >
            <.icon name="hero-sparkles" /> {gettext("Propose this sequence")}
          </.button>
          <.button id="undo" phx-click="undo" variant="secondary" disabled={@guess == []}>
            {gettext("Undo")}
          </.button>
          <.button id="clear" phx-click="clear" variant="ghost" disabled={@guess == []}>
            {gettext("Clear")}
          </.button>
        </div>
      </div>

      <section id="attempts" class="space-y-3" aria-labelledby="attempts-title">
        <h3 id="attempts-title" class="text-xl">{gettext("Attempts")}</h3>
        <p :if={@match["attempts"] == []} class="text-sm text-muted">{gettext("No attempt yet.")}</p>
        <ol class="space-y-3">
          <.attempt_row
            :for={attempt <- @match["attempts"]}
            attempt={attempt}
            name={Map.get(@names, attempt["user_id"], gettext("A player"))}
          />
        </ol>
      </section>
    </section>
    """
  end

  defp reward_text(%{"my_reward" => %{"status" => "awarded", "amount" => xp}}, _participant?),
    do: gettext("+%{xp} XP added to your progress.", xp: xp)

  defp reward_text(%{"my_reward" => %{"status" => "pending", "amount" => xp}}, _participant?),
    do: gettext("Your %{xp} XP are on their way to your progress.", xp: xp)

  defp reward_text(%{"my_reward" => %{"status" => "failed"}}, _participant?),
    do: gettext("Your XP couldn't be credited. This has been logged for the team.")

  defp reward_text(_match, true), do: gettext("You were away at the end: no XP this time.")

  defp reward_text(match, false),
    do: gettext("Players present at the end earned %{xp} XP each.", xp: match["xp_reward"])

  defp ready_check(assigns) do
    assigns = assign(assigns, :later?, scheduled_later?(assigns.lobby))

    ~H"""
    <section id="ready-check" class="card space-y-4" aria-labelledby="ready-title">
      <h2 id="ready-title" class="text-2xl">
        {if @match, do: gettext("Next game"), else: gettext("Ready check")}
      </h2>
      <p class="text-sm text-muted">
        {gettext("Mark yourself ready. The host starts the game once at least 2 players are ready.")}
      </p>
      <.notice :if={@later?} id="schedule-note" kind="reward">
        {gettext("Scheduled for %{time}: the game can't start before then.",
          time: datetime(@lobby["starts_at"])
        )}
      </.notice>
      <div class="flex flex-wrap gap-2">
        <.button
          id="ready-toggle"
          phx-click="ready"
          variant="secondary"
          aria-pressed={to_string(@my_ready?)}
        >
          <.icon name={if @my_ready?, do: "hero-check-circle", else: "hero-hand-raised"} />
          {if @my_ready?, do: gettext("Ready (select to cancel)"), else: gettext("I'm ready")}
        </.button>
        <.button
          :if={@host?}
          id="start-game"
          phx-click="start"
          disabled={@ready_count < 2 or @later?}
          phx-disable-with={gettext("Starting…")}
        >
          <.icon name="hero-play" /> {gettext("Start the game")}
        </.button>
      </div>
      <p id="ready-count" class="text-sm text-muted">
        {ngettext("%{count} player ready", "%{count} players ready", @ready_count)}
      </p>
    </section>
    """
  end

  defp members(assigns) do
    ~H"""
    <section id="members" class="card space-y-3" aria-labelledby="members-title">
      <h2 id="members-title" class="text-2xl">{gettext("Players")}</h2>
      <ul class="divide-y divide-line">
        <li
          :for={member <- @detail["members"]}
          id={"member-#{member["user"]["id"]}"}
          class="mp-member"
        >
          <div class="flex min-w-0 items-center gap-3">
            <.identity user={member["user"]}>
              <span :if={member["user"]["id"] == @me} class="text-muted">({gettext("you")})</span>
            </.identity>
          </div>
          <div class="flex flex-wrap gap-2">
            <.tag :if={member["host"]} kind="premium" icon="hero-star">{gettext("Host")}</.tag>
            <.tag
              :if={@lobby["status"] == "waiting" and member["ready"]}
              kind="success"
              icon="hero-check"
            >
              {gettext("Ready")}
            </.tag>
            <.tag :if={@lobby["status"] == "waiting" and !member["ready"]}>
              {gettext("Not ready")}
            </.tag>
            <.connection_tag connection={member["connection"]} />
          </div>
          <div :if={@member? and member["user"]["id"] != @me} class="flex flex-wrap gap-1">
            <.button
              :if={@host?}
              id={"transfer-#{member["user"]["id"]}"}
              phx-click="transfer"
              phx-value-id={member["user"]["id"]}
              variant="ghost"
              data-confirm={gettext("Hand the host role over to this player?")}
            >
              {gettext("Make host")}
            </.button>
            <.button
              :if={@host?}
              id={"kick-#{member["user"]["id"]}"}
              phx-click="kick"
              phx-value-id={member["user"]["id"]}
              variant="ghost"
              data-confirm={gettext("Remove this player? They won't be able to come back.")}
            >
              {gettext("Remove")}
            </.button>
            <.button
              id={"report-#{member["user"]["id"]}"}
              phx-click="report"
              phx-value-id={member["user"]["id"]}
              variant="ghost"
            >
              <.icon name="hero-flag" /> {gettext("Report")}
            </.button>
            <.button
              id={"block-#{member["user"]["id"]}"}
              phx-click="block"
              phx-value-id={member["user"]["id"]}
              variant="ghost"
              data-confirm={
                gettext("Block this member? You won't see each other's messages anymore.")
              }
            >
              <.icon name="hero-no-symbol" /> {gettext("Block")}
            </.button>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp chat(assigns) do
    ~H"""
    <section id="chat" class="card space-y-3" aria-labelledby="chat-title">
      <h2 id="chat-title" class="text-2xl">{gettext("Chat")}</h2>
      <p class="text-xs text-muted">
        {gettext("Messages from members you have blocked, or who blocked you, are hidden.")}
      </p>
      <.unavailable :if={@chat == :unavailable} id="chat-unavailable">
        {gettext("The chat can't be loaded right now.")}
      </.unavailable>
      <div role="log" aria-live="polite" aria-label={gettext("Lobby chat")}>
        <ol id="chat-log" class="mp-chat-log">
          <li :if={@messages == []} class="text-sm text-muted">{gettext("No message yet.")}</li>
          <li :for={message <- @messages || []} id={"chat-#{message["id"]}"} class="mp-chat-line">
            <p class="flex flex-wrap items-center gap-x-2 text-xs text-muted">
              <.identity user={message["user"]} />
              <span aria-hidden="true">·</span>
              <time datetime={message["inserted_at"]}>{message_time(message["inserted_at"])}</time>
            </p>
            <p class="whitespace-pre-wrap break-words">{message["body"]}</p>
          </li>
        </ol>
      </div>
      <.form for={@chat_form} id="chat-form" phx-submit="send" class="space-y-2">
        <.input
          field={@chat_form[:body]}
          label={gettext("Message")}
          maxlength="500"
          autocomplete="off"
        />
        <.button type="submit" id="chat-send" class="w-full">
          <.icon name="hero-paper-airplane" /> {gettext("Send")}
        </.button>
      </.form>
    </section>
    """
  end

  defp host_tools(assigns) do
    invited = MapSet.new(assigns.detail["invites"], & &1["invitee"]["id"])
    in_lobby = MapSet.new(assigns.detail["members"], & &1["user"]["id"])
    assigns = assign(assigns, invited: invited, in_lobby: in_lobby)

    ~H"""
    <section id="host-tools" class="card space-y-6" aria-labelledby="host-title">
      <h2 id="host-title" class="text-2xl">{gettext("Host tools")}</h2>

      <div :if={@detail["requests"] != []} id="requests" class="space-y-2">
        <h3 class="text-xl">{gettext("Requests to join")}</h3>
        <ul class="divide-y divide-line">
          <li
            :for={request <- @detail["requests"]}
            id={"request-#{request["user"]["id"]}"}
            class="member-row"
          >
            <span class="font-medium">{display_name(request["user"])}</span>
            <div class="flex flex-wrap gap-2">
              <.button
                id={"approve-#{request["user"]["id"]}"}
                phx-click="approve"
                phx-value-id={request["user"]["id"]}
              >
                {gettext("Approve")}
              </.button>
              <.button
                id={"decline-request-#{request["user"]["id"]}"}
                phx-click="decline_request"
                phx-value-id={request["user"]["id"]}
                variant="ghost"
              >
                {gettext("Decline")}
              </.button>
            </div>
          </li>
        </ul>
      </div>

      <div id="invite-friends" class="space-y-2">
        <h3 class="text-xl">{gettext("Invite friends")}</h3>
        <p class="text-sm text-muted">
          {gettext(
            "Only friends can be invited. Someone who has a block with a player here can't join."
          )}
        </p>
        <%= case @friends do %>
          <% :unavailable -> %>
            <.unavailable>{gettext("Your friends can't be loaded right now.")}</.unavailable>
          <% friends when friends in [nil, []] -> %>
            <p class="text-sm text-muted">
              {gettext("No friends to invite yet.")}
              <.link navigate={~p"/friends"} class="link">{gettext("Find friends")}</.link>
            </p>
          <% friends -> %>
            <p
              :if={Enum.all?(friends, &MapSet.member?(@in_lobby, &1["id"]))}
              class="text-sm text-muted"
            >
              {gettext("All your friends are already here.")}
            </p>
            <ul class="divide-y divide-line">
              <li
                :for={friend <- Enum.reject(friends, &MapSet.member?(@in_lobby, &1["id"]))}
                id={"friend-#{friend["id"]}"}
                class="member-row"
              >
                <span class="font-medium">{display_name(friend)}</span>
                <.tag :if={MapSet.member?(@invited, friend["id"])} kind="info" icon="hero-envelope">
                  {gettext("Invited")}
                </.tag>
                <.button
                  :if={!MapSet.member?(@invited, friend["id"])}
                  id={"invite-#{friend["id"]}"}
                  phx-click="invite"
                  phx-value-id={friend["id"]}
                  variant="secondary"
                >
                  <.icon name="hero-envelope" /> {gettext("Invite")}
                </.button>
              </li>
            </ul>
        <% end %>
      </div>

      <div id="invite-link" class="space-y-3">
        <h3 class="text-xl">{gettext("Invitation link")}</h3>
        <p class="text-sm text-muted">
          {gettext("Anyone with the link can join until it expires, is used up or is revoked.")}
        </p>
        <.form
          for={@link_form}
          id="link-form"
          phx-submit="create_link"
          class="grid gap-3 sm:grid-cols-2"
        >
          <.input
            field={@link_form[:max_uses]}
            type="select"
            label={gettext("Maximum uses")}
            options={[{"1", "1"}, {"2", "2"}, {"5", "5"}, {"10", "10"}, {"20", "20"}]}
          />
          <.input
            field={@link_form[:minutes]}
            type="select"
            label={gettext("Valid for")}
            options={[
              {gettext("15 minutes"), "15"},
              {gettext("1 hour"), "60"},
              {gettext("24 hours"), "1440"},
              {gettext("7 days"), "10080"}
            ]}
          />
          <.button type="submit" id="create-link" variant="secondary" class="sm:col-span-2">
            <.icon name="hero-link" /> {gettext("Create a link")}
          </.button>
        </.form>
        <div :if={@new_link} id="new-link" class="notice notice-reward" role="status">
          <div class="min-w-0 flex-1 space-y-2">
            <label for="new-link-url" class="label">{gettext(
              "Copy this link now: it won't be shown again."
            )}</label>
            <input
              id="new-link-url"
              class="input font-mono text-sm"
              type="text"
              readonly
              value={@new_link}
            />
          </div>
        </div>
        <ul :if={@detail["links"] != []} id="links" class="divide-y divide-line">
          <li :for={link <- @detail["links"]} id={"link-#{link["id"]}"} class="member-row">
            <div class="min-w-0 space-y-1 text-sm">
              <.tag kind={if link["state"] == "active", do: "success", else: "neutral"}>
                {link_state(link["state"])}
              </.tag>
              <p class="text-muted">
                {gettext("%{uses} of %{max} uses", uses: link["uses"], max: link["max_uses"])} · {gettext(
                  "expires %{time}",
                  time: datetime(link["expires_at"])
                )}
              </p>
            </div>
            <.button
              :if={link["state"] == "active"}
              id={"revoke-#{link["id"]}"}
              phx-click="revoke_link"
              phx-value-id={link["id"]}
              variant="danger"
            >
              {gettext("Revoke")}
            </.button>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp link_state("active"), do: gettext("Active")
  defp link_state("expired"), do: gettext("Expired")
  defp link_state("revoked"), do: gettext("Revoked")
  defp link_state(_), do: gettext("Used up")
end
