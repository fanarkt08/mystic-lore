defmodule MysticWeb.MultiplayerComponents do
  @moduledoc """
  Multiplayer components. Runes, marks and statuses are always written in words, never shown by colour alone.
  """
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  use Phoenix.VerifiedRoutes, endpoint: MysticWeb.Endpoint, router: MysticWeb.Router
  import MysticWeb.CoreComponents, only: [icon: 1]
  import MysticWeb.MysticComponents, only: [tag: 1]
  alias MysticWeb.Api

  # Written out so that Tailwind generates these `hero-*` classes.
  @rune_icons ~w(hero-fire hero-bolt hero-cloud hero-cube hero-sun hero-moon hero-star hero-eye)

  @doc "The 8 runes (ids 0..7, as the engine numbers them)."
  def runes, do: Enum.to_list(0..7)

  def rune_name(0), do: gettext("Ember")
  def rune_name(1), do: gettext("Storm")
  def rune_name(2), do: gettext("Mist")
  def rune_name(3), do: gettext("Stone")
  def rune_name(4), do: gettext("Sun")
  def rune_name(5), do: gettext("Moon")
  def rune_name(6), do: gettext("Star")
  def rune_name(7), do: gettext("Eye")
  def rune_name(_), do: "?"

  def rune_icon(id) when id in 0..7, do: Enum.at(@rune_icons, id)
  def rune_icon(_), do: "hero-sparkles"

  def sequence_text(sequence), do: Enum.map_join(sequence || [], ", ", &rune_name/1)

  @doc "A private clue, in words."
  def hint_text(%{"kind" => "at", "pos" => pos, "rune" => rune}),
    do: gettext("%{rune} is in position %{pos}.", rune: rune_name(rune), pos: pos + 1)

  def hint_text(%{"kind" => "not_at", "pos" => pos, "rune" => rune}),
    do: gettext("%{rune} is not in position %{pos}.", rune: rune_name(rune), pos: pos + 1)

  def hint_text(%{"kind" => "present", "rune" => rune}),
    do: gettext("%{rune} is part of the sequence.", rune: rune_name(rune))

  def hint_text(%{"kind" => "absent", "rune" => rune}),
    do: gettext("%{rune} is not in the sequence.", rune: rune_name(rune))

  def hint_text(%{"kind" => "before", "a" => a, "b" => b}),
    do: gettext("%{a} comes somewhere before %{b}.", a: rune_name(a), b: rune_name(b))

  def hint_text(_), do: gettext("Unknown clue.")

  def mark_label("hit"), do: gettext("right place")
  def mark_label("present"), do: gettext("wrong place")
  def mark_label(_), do: gettext("not in the sequence")

  def mark_icon("hit"), do: "hero-check-circle"
  def mark_icon("present"), do: "hero-arrows-right-left"
  def mark_icon(_), do: "hero-x-circle"

  def visibility_label("private"), do: gettext("Private")
  def visibility_label(_), do: gettext("Open")

  def role_label("host"), do: gettext("You are the host")
  def role_label("player"), do: gettext("You are a member")
  def role_label("pending"), do: gettext("Request pending")
  def role_label("invited"), do: gettext("You are invited")
  def role_label(_), do: gettext("You are watching")

  def display_name(nil), do: gettext("A former member")
  def display_name(user), do: MysticWeb.MysticComponents.member_name(user) || gettext("A member")

  @doc "A clear message for an error returned by the multiplayer service."
  def error_text(result) do
    case Api.error_code(result) do
      "full" ->
        gettext("This activity is full.")

      "banned" ->
        gettext("The host removed you from this activity: you can't join it again.")

      "blocked" ->
        gettext("This isn't possible: there is a block between you and a player here.")

      "not_friends" ->
        gettext("You can only invite your friends.")

      "lobby_invites_closed" ->
        gettext("This member doesn't accept activity invitations.")

      "already_member" ->
        gettext("This member is already in the activity.")

      "too_many_lobbies" ->
        gettext("You already host 3 activities. Leave one before creating another.")

      "too_many_links" ->
        gettext("5 links are already active. Revoke one first.")

      "in_progress" ->
        gettext("A game is in progress.")

      "not_yet" ->
        gettext("This activity is scheduled: it can't start before its start time.")

      "not_enough_ready" ->
        gettext("At least 2 ready players are needed to start.")

      "not_your_turn" ->
        gettext("It's not your turn yet.")

      "finished" ->
        gettext("This game is over.")

      "no_match" ->
        gettext("No game is in progress.")

      "conflict" ->
        gettext("The game moved on in the meantime. Please try again.")

      "not_participant" ->
        gettext("You are not playing in this game.")

      "rate_limited" ->
        gettext("You are sending messages too fast. Wait a few seconds.")

      "expired" ->
        gettext("This invitation link has expired.")

      "revoked" ->
        gettext("This invitation link has been revoked by the host.")

      "exhausted" ->
        gettext("This invitation link has already been used the maximum number of times.")

      "closed" ->
        gettext("This activity has ended.")

      "social_unavailable" ->
        gettext(
          "Friendships and blocks can't be checked right now, so this is refused for safety. Please try again in a moment."
        )

      _ ->
        generic_error(result)
    end
  end

  defp generic_error({:error, _} = error), do: Api.error_message(error)
  defp generic_error(_unexpected), do: gettext("Something went wrong. Please try again.")

  @doc "Lobby summary card (lists): the whole card links to the lobby."
  attr :lobby, :map, required: true
  attr :id, :string, required: true
  slot :actions

  def lobby_card(assigns) do
    ~H"""
    <article id={@id} class="mp-card">
      <div class="flex flex-wrap items-center gap-2">
        <.tag icon={
          if @lobby["visibility"] == "private", do: "hero-lock-closed", else: "hero-globe-alt"
        }>
          {visibility_label(@lobby["visibility"])}
        </.tag>
        <.tag :if={@lobby["requires_approval"]} icon="hero-hand-raised">{gettext("Approval")}</.tag>
        <.tag :if={@lobby["status"] == "playing"} kind="info" icon="hero-play">
          {gettext("Playing")}
        </.tag>
        <.tag :if={@lobby["role"]} kind="success">{role_label(@lobby["role"])}</.tag>
      </div>
      <h3 class="text-2xl break-words">
        <.link navigate={~p"/multiplayer/lobbies/#{@lobby["id"]}"} class="card-link">{@lobby["title"]}</.link>
      </h3>
      <p class="meta">
        <.icon name="hero-user-group" class="size-4" />
        {gettext("%{count} of %{max} players",
          count: @lobby["member_count"],
          max: @lobby["max_players"]
        )} · {gettext("Host: %{name}", name: display_name(@lobby["host"]))}
      </p>
      <p :if={@lobby["starts_at"]} class="meta">
        <.icon name="hero-calendar" class="size-4" />
        {gettext("Starts %{time}", time: MysticWeb.Format.datetime(@lobby["starts_at"]))}
      </p>
      <div :if={@actions != []} class="relative z-10 flex flex-wrap gap-2 pt-1">
        {render_slot(@actions)}
      </div>
    </article>
    """
  end

  @doc "Connection of a member, in words (presence comes from the heartbeats stored by the service)."
  attr :connection, :string, required: true

  def connection_tag(assigns) do
    ~H"""
    <%= case @connection do %>
      <% "online" -> %>
        <.tag kind="success" icon="hero-signal">{gettext("Online")}</.tag>
      <% "disconnected" -> %>
        <.tag kind="premium" icon="hero-arrow-path">{gettext("Reconnecting")}</.tag>
      <% _ -> %>
        <.tag icon="hero-signal-slash">{gettext("Away")}</.tag>
    <% end %>
    """
  end

  @doc "A rune: icon (decorative) + name."
  attr :rune, :integer, required: true
  attr :class, :any, default: nil

  def rune_face(assigns) do
    ~H"""
    <span class={["rune-face", "rune-tone-#{@rune}", @class]}>
      <.icon name={rune_icon(@rune)} class="size-5 shrink-0" />
      <span>{rune_name(@rune)}</span>
    </span>
    """
  end

  @doc "One attempt of the history: who, the five runes with their mark in words, and a summary."
  attr :attempt, :map, required: true
  attr :name, :string, required: true

  def attempt_row(assigns) do
    ~H"""
    <li id={"attempt-#{@attempt["n"]}"} class="mp-attempt">
      <p class="text-sm">
        <span class="font-semibold text-ink">
          {gettext("Attempt %{n} by %{name}", n: @attempt["n"], name: @name)}
        </span>
        <span class="text-muted">
          — {gettext("%{hits} in the right place, %{present} in the wrong place",
            hits: @attempt["hits"],
            present: @attempt["present"]
          )}
        </span>
      </p>
      <ol class="mp-marks" aria-label={gettext("Attempt %{n}", n: @attempt["n"])}>
        <li
          :for={
            {{rune, mark}, index} <-
              Enum.with_index(Enum.zip(@attempt["sequence"], @attempt["marks"]), 1)
          }
          class={["mp-mark", "mp-mark-#{mark}"]}
        >
          <span class="text-xs text-muted">{index}</span>
          <.rune_face rune={rune} />
          <span class="mp-mark-label">
            <.icon name={mark_icon(mark)} class="size-4 shrink-0" />{mark_label(mark)}
          </span>
        </li>
      </ol>
    </li>
    """
  end
end
