defmodule MysticWeb.MemberLive do
  @moduledoc """
  Profile of a member, filtered by accounts for the reader. A hidden academy record is never even fetched.
  """
  use MysticWeb, :live_view
  import MysticWeb.ProfileComponents
  alias MysticWeb.Social

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case Api.get(socket, :accounts, "/api/users/by-username/:username/profile",
           path_params: [username: username]
         ) do
      {:ok, %{"profile" => %{"id" => _} = member}} ->
        {:ok,
         socket
         |> assign(member: member, page_title: member["display_name"], reporting: false)
         |> assign(record: if(member["academy_record"], do: load_record(socket, member["id"])))
         |> load_relation()}

      {:error, {:http, 404, _}} ->
        raise MysticWeb.NotFoundError

      _ ->
        {:ok,
         assign(socket,
           member: :unavailable,
           page_title: gettext("Member"),
           reporting: false,
           relation: :visitor
         )}
    end
  end

  defp load_record(socket, member_id) do
    case Api.get(socket, :learning, "/api/users/:id/profile", path_params: [id: member_id]) do
      {:ok, %{"level" => _} = record} -> record
      _ -> :unavailable
    end
  end

  defp load_relation(%{assigns: %{current_user: nil}} = socket),
    do: assign(socket, relation: :visitor)

  defp load_relation(socket) do
    relation =
      if socket.assigns.member["id"] == socket.assigns.current_user["id"],
        do: :self,
        else: Social.relation(Social.relations(socket), socket.assigns.member["id"])

    assign(socket, relation: relation)
  end

  @impl true
  def handle_info({:friendship_changed, _user_id}, %{assigns: %{member: %{}}} = socket),
    do: {:noreply, load_relation(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Every action needs a member (social authorizes it again): visitors have none.
  @impl true
  def handle_event(_event, _params, %{assigns: %{current_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("message", %{"id" => user_id}, socket) do
    case Social.open_conversation(socket, user_id) do
      {:ok, id} -> {:noreply, push_navigate(socket, to: ~p"/messages/#{id}")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("report", _params, socket), do: {:noreply, assign(socket, reporting: true)}

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: false)}

  def handle_event("submit_report", %{"report" => params}, socket) do
    case Social.report(socket, socket.assigns.member["id"], params) do
      {:ok, message} ->
        {:noreply, socket |> put_flash(:info, message) |> assign(reporting: false)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(action, %{"id" => id}, socket) do
    if action in Social.actions() do
      socket =
        case Social.act(socket, action, id) do
          {:ok, message} -> put_flash(socket, :info, message)
          {:error, message} -> put_flash(socket, :error, message)
        end

      {:noreply, load_relation(socket)}
    else
      {:noreply, socket}
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
      active={:friends}
    >
      <div class="mx-auto max-w-3xl space-y-6">
        <.link :if={@current_user} navigate={~p"/friends"} class="link text-sm">
          ← {gettext("Friends")}
        </.link>
        <%= if @member == :unavailable do %>
          <.unavailable id="member-unavailable">
            {gettext("This profile can't be loaded right now.")}
          </.unavailable>
        <% else %>
          <.profile_card id="member-profile" name_id="member-name" profile={@member}>
            <:badges>
              <.tag :if={@relation == :friend} kind="success" icon="hero-check">
                {gettext("Friend")}
              </.tag>
              <.tag :if={@relation == :blocked} kind="danger" icon="hero-no-symbol">
                {gettext("Blocked")}
              </.tag>
            </:badges>
            <%= case @relation do %>
              <% :visitor -> %>
              <% :self -> %>
                <.notice kind="info">
                  {gettext("This is your public profile.")}
                  <:actions>
                    <.button navigate={~p"/settings"} variant="secondary">{gettext("Edit my profile")}</.button>
                    <.button navigate={~p"/settings/data"} variant="ghost">
                      {gettext("Who can see what")}
                    </.button>
                  </:actions>
                </.notice>
              <% :unknown -> %>
                <.unavailable>
                  {gettext("Friendship actions are unavailable right now.")}
                </.unavailable>
              <% relation -> %>
                <Social.member_actions user={@member} relation={relation} />
            <% end %>
          </.profile_card>

          <.record_card
            :if={@record}
            id="member-record"
            equipped_id="member-equipped"
            record={@record}
            self={@relation == :self}
          />

          <Social.report_panel :if={@reporting} user={@member} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
