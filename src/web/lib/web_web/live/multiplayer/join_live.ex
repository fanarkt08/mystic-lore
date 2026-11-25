defmodule MysticWeb.Multiplayer.JoinLive do
  @moduledoc """
  Invitation link page. Joining always needs a click, and an invalid link reveals nothing about the activity.
  """
  use MysticWeb, :live_view
  import MysticWeb.MultiplayerComponents

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket = assign(socket, page_title: gettext("Invitation"), token: token, error: nil)

    case Api.post(socket, :multiplayer, "/api/links/preview", json: %{token: token}) do
      {:ok, %{"lobby" => lobby}} ->
        {:ok, assign(socket, state: :valid, lobby: lobby)}

      {:error, {:http, status, _}} = error when status in [404, 410] ->
        {:ok, invalid(socket, error)}

      _ ->
        {:ok, assign(socket, state: :unavailable, lobby: nil)}
    end
  end

  defp invalid(socket, error) do
    reason = Api.error_code(error)
    reason = if reason in ~w(expired revoked exhausted closed), do: reason, else: "invalid"
    assign(socket, state: {:invalid, reason}, lobby: nil)
  end

  @impl true
  def handle_event("join", _params, socket) do
    case Api.post(socket, :multiplayer, "/api/links/join", json: %{token: socket.assigns.token}) do
      {:ok, %{"lobby_id" => id}} ->
        {:noreply, push_navigate(socket, to: ~p"/multiplayer/lobbies/#{id}")}

      {:error, {:http, status, _}} = error when status in [404, 410] ->
        {:noreply, invalid(socket, error)}

      {:error, {:http, 409, %{"error" => "full"}}} ->
        {:noreply, assign(socket, state: {:invalid, "full"}, lobby: nil)}

      error ->
        {:noreply, assign(socket, error: error_text(error))}
    end
  end

  defp invalid_title("expired"), do: gettext("This invitation link has expired")
  defp invalid_title("revoked"), do: gettext("This invitation link was revoked")
  defp invalid_title("exhausted"), do: gettext("This invitation link is used up")
  defp invalid_title("closed"), do: gettext("This activity has ended")
  defp invalid_title("full"), do: gettext("This activity is full")
  defp invalid_title(_), do: gettext("This invitation link isn't valid")

  defp invalid_text("expired"),
    do: gettext("Invitation links only work for a limited time. Ask the host for a new one.")

  defp invalid_text("revoked"),
    do:
      gettext(
        "The host disabled this link. Ask them for a new invitation if you still want to play."
      )

  defp invalid_text("exhausted"),
    do:
      gettext(
        "This link has already been used the maximum number of times. Ask the host for a new one."
      )

  defp invalid_text("closed"), do: gettext("Everyone has left this activity.")

  defp invalid_text("full"),
    do:
      gettext(
        "All the seats are taken for now. A seat may free up: check again in a moment, or ask the host about another activity."
      )

  defp invalid_text(_),
    do: gettext("Check that you copied the whole link, or ask the host for a new one.")

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
      <div class="mx-auto max-w-xl space-y-6">
        <p class="eyebrow">{gettext("Multiplayer invitation")}</p>
        <%= case @state do %>
          <% :valid -> %>
            <section id="invitation" class="panel space-y-4" aria-labelledby="invitation-title">
              <h1 id="invitation-title" class="text-4xl break-words">
                {gettext("Join “%{title}”", title: @lobby["title"])}
              </h1>
              <p class="text-muted">
                {gettext("%{name} invites you to a game of The Rune Relay.",
                  name: display_name(@lobby["host"])
                )}
              </p>
              <p class="meta">
                <.icon name="hero-user-group" class="size-4" />
                {gettext("%{count} of %{max} players",
                  count: @lobby["member_count"],
                  max: @lobby["max_players"]
                )}
              </p>
              <p
                :if={
                  is_integer(@lobby["member_count"]) and
                    @lobby["member_count"] >= @lobby["max_players"]
                }
                id="invitation-full"
                class="text-sm text-muted"
              >
                {gettext(
                  "Every seat is taken right now: you can still try, if one frees up you'll get in."
                )}
              </p>
              <p :if={@lobby["starts_at"]} class="meta">
                <.icon name="hero-calendar" class="size-4" />
                {gettext("Starts %{time}", time: datetime(@lobby["starts_at"]))}
              </p>
              <.notice :if={@error} id="join-error" kind="danger" role="alert">{@error}</.notice>
              <.button
                id="join-link"
                phx-click="join"
                class="w-full"
                phx-disable-with={gettext("Joining…")}
              >
                <.icon name="hero-user-plus" /> {gettext("Join this activity")}
              </.button>
            </section>
          <% {:invalid, reason} -> %>
            <.access_state
              id="link-invalid"
              icon={if reason == "full", do: "hero-user-group", else: "hero-link-slash"}
              title={invalid_title(reason)}
              live
            >
              {invalid_text(reason)}
              <:actions>
                <.button
                  :if={reason == "full"}
                  navigate={~p"/multiplayer/join/#{@token}"}
                  variant="secondary"
                  id="link-check-again"
                >
                  <.icon name="hero-arrow-path" /> {gettext("Check again")}
                </.button>
                <.button navigate={~p"/multiplayer"} variant="secondary" id="link-browse">
                  {gettext("Browse open activities")}
                </.button>
              </:actions>
            </.access_state>
          <% :unavailable -> %>
            <.unavailable id="link-unavailable">
              {gettext("This invitation can't be checked right now.")}
            </.unavailable>
        <% end %>
        <.link navigate={~p"/multiplayer"} class="link">{gettext("Browse open activities")}</.link>
      </div>
    </Layouts.app>
    """
  end
end
