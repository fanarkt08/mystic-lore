defmodule MysticWeb.MessagesLive do
  @moduledoc """
  Conversations and the real-time thread. The view never subscribes to a conversation topic, so a member
  removed from a group receives nothing more.
  """
  use MysticWeb, :live_view
  import MysticWeb.MessagesComponents
  alias MysticWeb.{Presence, Social}

  @max_upload 10 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Presence.subscribe()

    {:ok,
     socket
     |> assign(page_title: gettext("Messages"), conversation: nil, people: %{}, panel: false)
     # new messages show up live here: no notification toast of the `messages` category on this page
     |> assign(toast_except: ["messages"])
     |> assign(next_before: nil, thread: :ok, locked: nil, form: composer_form(), reporting: nil)
     |> assign(last: nil, throttled: nil, upload_errors: [], group_errors: [])
     |> assign(group_form: group_form(), rename_form: to_form(%{"name" => ""}, as: :group))
     |> assign(online: if(connected?(socket), do: Presence.online_ids(), else: MapSet.new()))
     |> stream_configure(:messages, dom_id: &"message-#{&1["id"]}")
     |> stream(:messages, [])
     |> allow_upload(:attachment,
       accept: ~w(.png .jpg .jpeg .webp .pdf),
       max_entries: 1,
       max_file_size: @max_upload,
       auto_upload: true
     )
     |> load_friends()
     |> load_conversations()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket), do: {:noreply, open(socket, id)}

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    {:noreply,
     socket
     |> assign(conversation: nil, page_title: gettext("New group"), group_errors: [])
     |> assign(group_form: group_form())}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, conversation: nil, page_title: gettext("Messages"))}

  ## Loading

  defp load_conversations(socket) do
    case Api.get(socket, :social, "/api/me/conversations") do
      {:ok, %{"conversations" => list}} when is_list(list) -> assign(socket, conversations: list)
      _ -> assign(socket, conversations: :unavailable)
    end
  end

  # Friends (with `online_visible`): lock of a direct conversation, group creation and additions, online dots.
  defp load_friends(socket) do
    case Api.get(socket, :social, "/api/me/friends") do
      {:ok, %{"friends" => friends}} when is_list(friends) -> assign(socket, friends: friends)
      _ -> assign(socket, friends: :unavailable)
    end
  end

  defp open(socket, id) do
    socket =
      assign(socket,
        next_before: nil,
        locked: nil,
        form: composer_form(),
        panel: false,
        last: nil,
        reporting: nil,
        upload_errors: []
      )

    case fetch_conversation(socket, id) do
      {:ok, conversation} ->
        socket
        |> put_conversation(conversation)
        |> load_history()
        |> check_lock()
        |> mark_read()

      {:error, state} ->
        socket |> assign(conversation: state, people: %{}) |> stream(:messages, [], reset: true)
    end
  end

  defp fetch_conversation(socket, id) do
    case Api.get(socket, :social, "/api/conversations/:id", path_params: [id: id]) do
      {:ok, %{"conversation" => %{"id" => _} = conversation}} -> {:ok, conversation}
      {:error, {:http, 404, _}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  defp put_conversation(socket, conversation) do
    people = Map.new(conversation["members"] || [], &{&1["user"]["id"], &1["user"]})

    socket
    |> assign(
      conversation: conversation,
      people: Map.merge(socket.assigns.people, people),
      page_title: title(conversation),
      rename_form: to_form(%{"name" => conversation["name"] || ""}, as: :group)
    )
  end

  defp load_history(socket) do
    case Api.get(socket, :social, "/api/conversations/:id/messages",
           path_params: [id: conversation_id(socket)]
         ) do
      {:ok, %{"entries" => entries} = page} ->
        socket
        |> add_people(page["users"])
        |> assign(thread: :ok, next_before: page["next_before"], last: List.last(entries))
        |> stream(:messages, entries, reset: true)
        |> push_event("thread:bottom", %{})

      _ ->
        socket |> assign(thread: :unavailable) |> stream(:messages, [], reset: true)
    end
  end

  defp add_people(socket, users) when is_list(users),
    do: update(socket, :people, &Map.merge(&1, Map.new(users, fn u -> {u["id"], u} end)))

  defp add_people(socket, _users), do: socket

  # Sending in a direct conversation needs an active friendship (social re-checks it on every send).
  defp check_lock(%{assigns: %{conversation: %{"kind" => "direct", "other" => other}}} = socket) do
    case socket.assigns.friends do
      friends when is_list(friends) ->
        if Enum.any?(friends, &(&1["id"] == other["id"])),
          do: assign(socket, locked: nil),
          else: assign(socket, locked: locked_message())

      _ ->
        socket
    end
  end

  defp check_lock(socket), do: socket

  defp locked_message,
    do:
      gettext(
        "You can still read this conversation, but you can't send messages anymore: you are no longer friends, or one of you has blocked the other."
      )

  defp mark_read(socket) do
    if connected?(socket) do
      id = conversation_id(socket)
      Api.post(socket, :social, "/api/conversations/:id/read", path_params: [id: id])

      update(socket, :conversations, fn
        list when is_list(list) ->
          Enum.map(list, &if(&1["id"] == id, do: Map.put(&1, "unread", 0), else: &1))

        other ->
          other
      end)
    else
      socket
    end
  end

  # Reload the open conversation (members, name, receipts); a 404 means the member left or was removed.
  defp refresh(socket) do
    case fetch_conversation(socket, conversation_id(socket)) do
      {:ok, conversation} ->
        socket |> put_conversation(conversation) |> check_lock()

      {:error, :not_found} ->
        socket
        |> assign(conversation: :not_found, people: %{}, panel: false)
        |> stream(:messages, [], reset: true)

      {:error, :unavailable} ->
        socket
    end
  end

  defp conversation_id(socket), do: socket.assigns.conversation["id"]

  defp open?(socket, id), do: match?(%{"id" => ^id}, socket.assigns.conversation)

  defp composer_form(values \\ %{"body" => "", "alt" => ""}, errors \\ []),
    do: to_form(values, as: :message, errors: errors)

  defp group_form(values \\ %{"name" => "", "member_ids" => []}, errors \\ []),
    do: to_form(values, as: :group, errors: errors)

  ## Real time

  @impl true
  def handle_info({:new_message, %{"conversation_id" => id} = message}, socket) do
    socket =
      if message["sender_id"] == me(socket) or message["kind"] == "system",
        do: load_conversations(socket),
        else: socket

    if open?(socket, id) do
      socket =
        if message["kind"] == "system", do: refresh(socket), else: socket

      socket =
        socket
        |> stream_insert(:messages, message)
        |> assign(last: message)
        |> push_event("thread:bottom", %{})

      if message["sender_id"] != me(socket),
        do: {:noreply, mark_read(socket)},
        else: {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_removed, %{"conversation_id" => id} = message}, socket) do
    socket = load_conversations(socket)

    if open?(socket, id),
      do: {:noreply, stream_insert(socket, :messages, message)},
      else: {:noreply, socket}
  end

  def handle_info({:messages_read, id, %{"user_id" => reader} = read}, socket) do
    if open?(socket, id) do
      {:noreply,
       update(socket, :conversation, fn c ->
         receipts = c["read_receipts"] || %{"enabled" => true, "reads" => []}
         reads = [read | Enum.reject(receipts["reads"], &(&1["user_id"] == reader))]
         Map.put(c, "read_receipts", Map.put(receipts, "reads", reads))
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:conversation_changed, id}, socket) do
    socket = load_conversations(socket)
    if open?(socket, id), do: {:noreply, refresh(socket)}, else: {:noreply, socket}
  end

  def handle_info({:unread_changed, _user_id}, socket), do: {:noreply, load_conversations(socket)}

  def handle_info(
        {:social_settings_changed, _user_id},
        %{assigns: %{conversation: %{}}} = socket
      ),
      do: {:noreply, refresh(socket)}

  def handle_info({:friendship_changed, _user_id}, socket),
    do: {:noreply, socket |> load_friends() |> check_lock()}

  # a restriction was lifted (or set): the composer state follows
  def handle_info({:sanction_changed, _user_id}, socket), do: {:noreply, check_lock(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, online: Presence.online_ids())}

  def handle_info(:throttle_over, socket), do: {:noreply, assign(socket, throttled: nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp me(socket), do: socket.assigns.current_user["id"]

  ## Composer

  @impl true
  def handle_event("validate", %{"message" => params}, socket),
    do: {:noreply, assign(socket, form: composer_form(Map.take(params, ~w(body alt))))}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, socket |> cancel_upload(:attachment, ref) |> assign(upload_errors: [])}

  def handle_event("send", %{"message" => params}, socket) do
    body = String.trim(to_string(params["body"]))
    values = %{"body" => params["body"] || "", "alt" => params["alt"] || ""}
    file = pending_file(socket)

    cond do
      file == :uploading ->
        message = gettext("The file is still uploading. Send it once the progress bar is full.")
        {:noreply, assign(socket, form: composer_form(values), upload_errors: [message])}

      body == "" and is_nil(file) ->
        message = gettext("Write a message or attach a file first.")
        {:noreply, assign(socket, form: composer_form(values, body: {message, []}))}

      String.length(body) > 2000 ->
        message = gettext("Messages are limited to 2,000 characters.")
        {:noreply, assign(socket, form: composer_form(values, body: {message, []}))}

      true ->
        payload =
          %{body: if(body != "", do: body)}
          |> then(fn p ->
            if file, do: Map.put(p, :attachment, attachment_payload(file, values["alt"])), else: p
          end)

        socket
        |> Api.post(:social, "/api/conversations/:id/messages",
          path_params: [id: conversation_id(socket)],
          json: payload,
          receive_timeout: 30_000
        )
        |> sent(socket, values)
    end
  end

  def handle_event("load_older", _params, %{assigns: %{next_before: before}} = socket)
      when is_binary(before) do
    case Api.get(socket, :social, "/api/conversations/:id/messages",
           path_params: [id: conversation_id(socket)],
           params: [before: before]
         ) do
      {:ok, %{"entries" => entries} = page} ->
        # Inserting at 0 one by one reverses the order: feed the batch newest first.
        {:noreply,
         socket
         |> add_people(page["users"])
         |> stream(:messages, Enum.reverse(entries), at: 0)
         |> assign(next_before: page["next_before"])}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("load_older", _params, socket), do: {:noreply, socket}

  def handle_event("report_message", %{"id" => id}, socket),
    do: {:noreply, assign(socket, reporting: id)}

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: nil)}

  def handle_event("submit_report", %{"report" => params}, socket) do
    case Social.report_message(socket, socket.assigns.reporting, params) do
      {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> assign(reporting: nil)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  ## Details: mute and group management

  def handle_event("toggle_panel", _params, socket),
    do: {:noreply, update(socket, :panel, &(!&1))}

  def handle_event("mute", %{"mute" => %{"duration" => duration}}, socket) do
    socket
    |> Api.put(:social, "/api/conversations/:id/mute",
      path_params: [id: conversation_id(socket)],
      json: %{duration: duration}
    )
    |> changed(socket)
  end

  def handle_event("unmute", _params, socket) do
    socket
    |> Api.delete(:social, "/api/conversations/:id/mute",
      path_params: [id: conversation_id(socket)]
    )
    |> changed(socket)
  end

  def handle_event("rename", %{"group" => %{"name" => name}}, socket) do
    case Api.patch(socket, :social, "/api/conversations/:id",
           path_params: [id: conversation_id(socket)],
           json: %{name: name}
         ) do
      {:error, {:http, 422, _}} = error ->
        errors = Api.form_errors(error, [:name])

        {:noreply,
         assign(socket, rename_form: to_form(%{"name" => name}, as: :group, errors: errors))}

      result ->
        changed(result, socket)
    end
  end

  def handle_event("add_member", %{"member" => %{"user_id" => user_id}}, socket) do
    socket
    |> Api.post(:social, "/api/conversations/:id/members",
      path_params: [id: conversation_id(socket)],
      json: %{user_id: user_id}
    )
    |> changed(socket)
  end

  def handle_event("remove_member", %{"id" => user_id}, socket) do
    socket
    |> Api.delete(:social, "/api/conversations/:id/members/:user_id",
      path_params: [id: conversation_id(socket), user_id: user_id]
    )
    |> changed(socket)
  end

  def handle_event("leave", _params, socket) do
    case Api.post(socket, :social, "/api/conversations/:id/leave",
           path_params: [id: conversation_id(socket)]
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You left the group."))
         |> load_conversations()
         |> push_patch(to: ~p"/messages")}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("create_group", %{"group" => params}, socket) do
    name = to_string(params["name"])
    ids = params |> Map.get("member_ids", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    values = %{"name" => name, "member_ids" => ids}

    case Api.post(socket, :social, "/api/groups", json: %{name: name, member_ids: ids}) do
      {:ok, %{"conversation" => %{"id" => id}}} ->
        {:noreply, socket |> load_conversations() |> push_patch(to: ~p"/messages/#{id}")}

      {:error, {:http, 422, %{"errors" => errors}}} = error ->
        {:noreply,
         assign(socket,
           group_form: group_form(values, Api.form_errors(error, [:name])),
           group_errors: List.wrap(errors["member_ids"])
         )}

      {:error, {:http, 403, %{"user_id" => user_id}}} = error ->
        refused = Enum.find(List.wrap(socket.assigns.friends), &(&1["id"] == user_id))

        message =
          gettext("%{name} can't be added: %{reason}",
            name: name(refused),
            reason: Api.error_message(error)
          )

        {:noreply, assign(socket, group_form: group_form(values), group_errors: [message])}

      error ->
        {:noreply,
         socket
         |> assign(group_form: group_form(values))
         |> put_flash(:error, Api.error_message(error))}
    end
  end

  # Result of a change to the open conversation: the conversation returned by social is shown at once (header,
  # member list and mute status say it), without a toast over the header.
  defp changed({:ok, %{"conversation" => %{"id" => _} = conversation}}, socket) do
    {:noreply, socket |> put_conversation(conversation) |> load_conversations()}
  end

  defp changed(error, socket),
    do: {:noreply, socket |> refresh() |> put_flash(:error, Api.error_message(error))}

  ## Sending

  # The file of the composer, read without consuming it (`:postpone`): a refused send keeps it for a new try.
  defp pending_file(socket) do
    case uploaded_entries(socket, :attachment) do
      {[entry], []} ->
        [bytes] =
          consume_uploaded_entries(socket, :attachment, fn %{path: path}, _entry ->
            {:postpone, File.read!(path)}
          end)

        %{bytes: bytes, name: entry.client_name}

      {[], [_uploading]} ->
        :uploading

      _ ->
        nil
    end
  end

  defp attachment_payload(file, alt),
    do: %{data_base64: Base.encode64(file.bytes), filename: file.name, alt: alt}

  defp sent({:ok, %{"message" => %{"id" => _} = message}}, socket, _values) do
    consume_uploaded_entries(socket, :attachment, fn _meta, _entry -> {:ok, nil} end)

    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> assign(form: composer_form(), upload_errors: [], last: message)
     |> load_conversations()
     |> push_event("thread:bottom", %{})}
  end

  defp sent({:error, {:http, 429, %{"retry_after" => seconds}}} = error, socket, values)
       when is_integer(seconds) do
    Process.send_after(self(), :throttle_over, seconds * 1000)

    {:noreply, assign(socket, throttled: Api.error_message(error), form: composer_form(values))}
  end

  defp sent({:error, {:http, 403, %{"error" => code}}} = error, socket, values)
       when code in ["blocked", "not_friends", "restricted"],
       do:
         {:noreply, assign(socket, locked: Api.error_message(error), form: composer_form(values))}

  defp sent({:error, {:http, 422, %{"errors" => errors}}} = error, socket, values) do
    file_errors = List.wrap(errors["attachment"]) ++ List.wrap(errors["alt"])

    {:noreply,
     assign(socket,
       form: composer_form(values, Api.form_errors(error, [:body])),
       upload_errors: file_errors
     )}
  end

  defp sent({:error, {:http, 503, %{"error" => "scanner_unavailable"}}} = error, socket, values),
    do:
      {:noreply,
       assign(socket, upload_errors: [Api.error_message(error)], form: composer_form(values))}

  defp sent(error, socket, values) do
    {:noreply, assign(socket, form: composer_form(values, body: {Api.error_message(error), []}))}
  end

  ## Rendering helpers

  defp receipt(%{"read_receipts" => %{"enabled" => true, "reads" => reads}} = c, last, me, people)
       when is_map(last) do
    with %{"sender_id" => ^me, "kind" => "text", "inserted_at" => at} <- last,
         {:ok, at, _} <- DateTime.from_iso8601(at) do
      readers =
        for r <- reads,
            {:ok, read_at, _} <- [DateTime.from_iso8601(r["read_at"])],
            DateTime.compare(read_at, at) != :lt,
            do: name(people[r["user_id"]])

      cond do
        readers == [] ->
          nil

        c["kind"] == "direct" ->
          gettext("Seen")

        true ->
          ngettext("Seen by %{count}: %{names}", "Seen by %{count}: %{names}", length(readers),
            names: Enum.join(readers, ", ")
          )
      end
    else
      _ -> nil
    end
  end

  defp receipt(_conversation, _last, _me, _people), do: nil

  defp other_online?(%{"kind" => "direct", "other" => %{"id" => id}}, friends, online),
    do: MapSet.member?(Presence.visible(friends, online), id)

  defp other_online?(_conversation, _friends, _online), do: false

  defp upload_error(:too_large), do: gettext("larger than 10 MB")
  defp upload_error(:not_accepted), do: gettext("not a PNG, JPEG, WebP or PDF file")
  defp upload_error(:too_many_files), do: gettext("one file at a time")
  defp upload_error(_), do: gettext("can't be uploaded")

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        visible_online: Presence.visible(assigns.friends, assigns.online),
        receipt:
          is_map(assigns.conversation) &&
            receipt(
              assigns.conversation,
              assigns.last,
              assigns.current_user["id"],
              assigns.people
            )
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:messages}
    >
      <div class="messages-layout">
        <section
          class={["conversation-list", @live_action in [:show, :new] && "hidden md:flex"]}
          aria-labelledby="conversations-title"
        >
          <div class="flex items-start justify-between gap-2 p-4">
            <div class="min-w-0 space-y-1">
              <h1 id="conversations-title" class="text-3xl">{gettext("Messages")}</h1>
              <p class="text-xs text-muted">{gettext("Private conversations with your friends.")}</p>
            </div>
            <.button
              patch={~p"/messages/new"}
              variant="secondary"
              id="new-group"
              title={gettext("New group")}
            >
              <.icon name="hero-user-group" />
              <span class="sr-only">{gettext("New group")}</span>
            </.button>
          </div>
          <%= case @conversations do %>
            <% :unavailable -> %>
              <div class="p-4">
                <.unavailable>{gettext("Conversations can't be loaded right now.")}</.unavailable>
              </div>
            <% [] -> %>
              <div class="space-y-3 p-4 text-sm text-muted">
                <p>{gettext("No conversation yet.")}</p>
                <.link navigate={~p"/friends"} class="link">{gettext(
                  "Message a friend from your friends list"
                )} →</.link>
              </div>
            <% list -> %>
              <ul id="conversations" class="overflow-y-auto">
                <li :for={c <- list} id={"conversation-#{c["id"]}"}>
                  <.link
                    patch={~p"/messages/#{c["id"]}"}
                    class="conversation-link"
                    aria-current={is_map(@conversation) && @conversation["id"] == c["id"] && "page"}
                  >
                    <.conversation_avatar
                      conversation={c}
                      online={other_online?(c, @friends, @online)}
                    />
                    <span class="min-w-0 flex-1">
                      <span class="flex items-baseline justify-between gap-2">
                        <span class="min-w-0 break-words">
                          <span class="font-medium text-ink">{title(c)}</span>
                          <span :if={c["kind"] == "direct"} class="identity-handle">
                            @{c["other"]["username"]}
                          </span>
                        </span>
                        <span :if={c["last_message"]} class="shrink-0 text-xs text-muted">
                          {message_time(c["last_message"]["inserted_at"])}
                        </span>
                      </span>
                      <span class="conversation-preview block truncate text-sm text-muted">
                        {preview(c["last_message"], c, @current_user["id"])}
                      </span>
                    </span>
                    <span :if={c["muted"]} class="text-muted" title={gettext("Muted")}>
                      <.icon name="hero-bell-slash" class="size-4" />
                      <span class="sr-only">{gettext("Muted")}</span>
                    </span>
                    <.count_badge
                      count={c["unread"]}
                      label={gettext("unread messages")}
                      class={c["muted"] && "count-badge-muted"}
                    />
                  </.link>
                </li>
              </ul>
          <% end %>
        </section>

        <section
          class={["thread", @live_action == :index && "hidden md:flex"]}
          aria-label={gettext("Conversation")}
        >
          <%= case {@live_action, @conversation} do %>
            <% {:new, _} -> %>
              <.new_group form={@group_form} friends={@friends} errors={@group_errors} />
            <% {_, nil} -> %>
              <div class="m-auto p-8">
                <.empty_state
                  icon="hero-chat-bubble-left-right"
                  title={gettext("Choose a conversation")}
                >
                  {gettext("Select a friend or a group on the left to read and send messages.")}
                </.empty_state>
              </div>
            <% {_, :not_found} -> %>
              <div class="space-y-4 p-6">
                <.link patch={~p"/messages"} class="link md:hidden">← {gettext("All conversations")}</.link>
                <.notice
                  id="conversation-not-found"
                  kind="danger"
                  title={gettext("Conversation not found")}
                >
                  {gettext("This conversation doesn't exist or you are not part of it (anymore).")}
                </.notice>
              </div>
            <% {_, :unavailable} -> %>
              <div class="space-y-4 p-6">
                <.link patch={~p"/messages"} class="link md:hidden">← {gettext("All conversations")}</.link>
                <.unavailable id="conversation-unavailable">
                  {gettext("This conversation can't be loaded right now.")}
                </.unavailable>
              </div>
            <% {_, conversation} -> %>
              <header class="thread-header">
                <.link
                  patch={~p"/messages"}
                  class="btn btn-ghost md:hidden"
                  aria-label={gettext("All conversations")}
                >
                  <.icon name="hero-arrow-left" />
                </.link>
                <.conversation_avatar
                  conversation={conversation}
                  online={other_online?(conversation, @friends, @online)}
                />
                <div class="min-w-0 flex-1">
                  <h2 id="thread-title" class="break-words font-display text-2xl text-ink">
                    {title(conversation)}
                  </h2>
                  <%= if conversation["kind"] == "group" do %>
                    <p id="thread-subtitle" class="break-words text-xs text-muted">
                      {ngettext(
                        "%{count} member",
                        "%{count} members",
                        length(conversation["members"])
                      )}
                    </p>
                  <% else %>
                    <.link
                      navigate={~p"/members/#{conversation["other"]["username"]}"}
                      class="text-xs text-muted hover:text-magic"
                    >
                      @{conversation["other"]["username"]}
                    </.link>
                  <% end %>
                </div>
                <span :if={conversation["muted"]} id="thread-muted" class="text-muted">
                  <.icon name="hero-bell-slash" class="size-5" />
                  <span class="sr-only">{gettext("Muted")}</span>
                </span>
                <.button
                  type="button"
                  variant="ghost"
                  id="toggle-details"
                  phx-click="toggle_panel"
                  aria-expanded={to_string(@panel)}
                  aria-controls="details-panel"
                >
                  <.icon name={
                    if conversation["kind"] == "group",
                      do: "hero-user-group",
                      else: "hero-adjustments-horizontal"
                  } />
                  <span class="sr-only">{gettext("Conversation details")}</span>
                </.button>
              </header>
              <.details_panel
                :if={@panel}
                conversation={conversation}
                me={@current_user["id"]}
                friends={@friends}
                online={@visible_online}
                rename_form={@rename_form}
              />
              <p class="thread-notice">
                <.icon name="hero-lock-open" class="size-4" />
                {gettext("Messages are not end-to-end encrypted.")}
              </p>
              <div id="thread-scroll" class="thread-scroll" phx-hook=".ThreadScroll">
                <div :if={@next_before} class="flex justify-center py-2">
                  <.button phx-click="load_older" variant="ghost" id="load-older">{gettext(
                    "Load older messages"
                  )}</.button>
                </div>
                <.unavailable :if={@thread == :unavailable}>
                  {gettext("Messages can't be loaded right now.")}
                </.unavailable>
                <div role="log" aria-live="polite" aria-label={gettext("Messages")}>
                  <ol id="messages" phx-update="stream" class="space-y-3">
                    <li
                      id="messages-empty"
                      class="hidden only:block py-8 text-center text-sm text-muted"
                    >
                      {gettext("No message yet. Say hello!")}
                    </li>
                    <.message
                      :for={{dom_id, message} <- @streams.messages}
                      id={dom_id}
                      message={message}
                      me={@current_user["id"]}
                      group={conversation["kind"] == "group"}
                      people={@people}
                    />
                  </ol>
                </div>
                <p :if={@receipt} id="read-receipt" class="read-receipt">
                  <.icon name="hero-check" class="size-4" /> {@receipt}
                </p>
              </div>
              <div :if={@reporting} class="mx-4 mb-2">
                <Social.report_panel
                  user={conversation["other"] || %{}}
                  title={gettext("Report this message")}
                />
              </div>
              <.notice :if={@locked} id="composer-locked" kind="warning" class="mx-4 mb-2">
                {@locked}
              </.notice>
              <.notice
                :if={@throttled}
                id="composer-throttled"
                kind="warning"
                class="mx-4 mb-2"
                role="alert"
              >
                {@throttled}
              </.notice>
              <.form
                for={@form}
                id="composer"
                phx-change="validate"
                phx-submit="send"
                class="composer"
              >
                <div
                  :for={entry <- @uploads.attachment.entries}
                  id={"upload-#{entry.ref}"}
                  class="composer-upload"
                >
                  <div class="flex min-w-0 flex-1 flex-col gap-1">
                    <span class="truncate text-sm font-medium text-ink">{entry.client_name}</span>
                    <.progress
                      value={entry.progress}
                      label={gettext("Upload of %{name}", name: entry.client_name)}
                    />
                    <span
                      :for={err <- upload_errors(@uploads.attachment, entry)}
                      class="text-sm text-danger"
                    >
                      {upload_error(err)}
                    </span>
                  </div>
                  <.input
                    :if={String.starts_with?(entry.client_type || "", "image/")}
                    field={@form[:alt]}
                    id="attachment-alt"
                    label={gettext("Image description (alternative text)")}
                    maxlength="300"
                    class="composer-alt"
                  />
                  <.button
                    type="button"
                    variant="ghost"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    id={"cancel-upload-#{entry.ref}"}
                  >
                    <.icon name="hero-x-mark" />
                    <span class="sr-only">{gettext("Remove the attachment")}</span>
                  </.button>
                </div>
                <p :if={@upload_errors != []} id="attachment-error" class="field-error composer-error">
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
                  <span>{Enum.join(Enum.map(@upload_errors, &translate_error({&1, []})), " · ")}</span>
                </p>
                <div class="composer-row">
                  <span class="composer-attach">
                    <.live_file_input
                      upload={@uploads.attachment}
                      disabled={@locked != nil}
                      aria-describedby="attachment-hint"
                      title={gettext("Attach an image or a PDF")}
                    />
                    <label
                      for={@uploads.attachment.ref}
                      class="btn btn-ghost"
                      title={gettext("Attach an image or a PDF")}
                    >
                      <.icon name="hero-paper-clip" />
                      <span class="sr-only">{gettext("Attach an image or a PDF")}</span>
                    </label>
                    <span id="attachment-hint" class="sr-only">
                      {gettext("PNG, JPEG or WebP up to 5 MB, or PDF up to 10 MB.")}
                    </span>
                  </span>
                  <div class="min-w-0 flex-1">
                    <.input
                      field={@form[:body]}
                      type="textarea"
                      rows="2"
                      maxlength="2000"
                      disabled={@locked != nil}
                      label={gettext("Write a message to %{name}", name: title(conversation))}
                    />
                  </div>
                  <.button
                    type="submit"
                    id="send-message"
                    disabled={@locked != nil or @throttled != nil}
                    phx-disable-with={gettext("Sending…")}
                  >
                    <.icon name="hero-paper-airplane" />
                    <span class="sr-only md:not-sr-only">{gettext("Send")}</span>
                  </.button>
                </div>
              </.form>
          <% end %>
        </section>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ThreadScroll">
        import {scrollBehavior} from "@/js/motion"
        // opens at the latest message; new messages glide into view (instantly when motion is reduced);
        // an image that finishes loading keeps the thread at the bottom unless the member scrolled up
        export default {
          mounted() {
            this.el.scrollTop = this.el.scrollHeight
            this.handleEvent("thread:bottom", () =>
              this.el.scrollTo({top: this.el.scrollHeight, behavior: scrollBehavior()}))
            this.el.addEventListener("load", (e) => {
              const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
              if (e.target.tagName === "IMG" && gap < e.target.clientHeight + 200)
                this.el.scrollTop = this.el.scrollHeight
            }, true)
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
