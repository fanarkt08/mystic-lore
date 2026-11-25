defmodule MysticWeb.MessagesComponents do
  @moduledoc "Components of `/messages`: conversation rows, message bubbles, details panel and group form."
  use MysticWeb, :html

  ## Names

  @doc "Display name of a member (`people` map or user), with a fallback (« Deleted member » translated)."
  def name(user), do: member_name(user) || gettext("Unknown member")

  def title(%{"kind" => "group", "name" => name}), do: name
  def title(%{"other" => other}), do: name(other)

  # « Deleted member » stays whole (its first word alone would read as a real name)
  defp first_name(user) do
    if deleted_member?(user || %{}),
      do: name(user),
      else: user |> name() |> String.split(" ", parts: 2) |> hd()
  end

  @doc "Sentence of a system message of a group."
  def system_text(%{"system" => system}, people) do
    actor = name(people[system["actor_id"]])
    target = name(people[system["target_id"]])

    case system["event"] do
      "created" ->
        gettext("%{actor} created the group “%{name}”.", actor: actor, name: system["name"])

      "renamed" ->
        gettext("%{actor} renamed the group “%{name}”.", actor: actor, name: system["name"])

      "member_added" ->
        gettext("%{actor} added %{target}.", actor: actor, target: target)

      "member_removed" ->
        gettext("%{actor} removed %{target} from the group.", actor: actor, target: target)

      "member_left" ->
        if system["target_id"],
          do:
            gettext("%{actor} left the group. %{target} is now its owner.",
              actor: actor,
              target: target
            ),
          else: gettext("%{actor} left the group.", actor: actor)

      _other ->
        gettext("The group changed.")
    end
  end

  @doc "Preview of the last message in the conversation list (never more than one line)."
  def preview(nil, _conversation, _me), do: gettext("No message yet")

  def preview(%{"removed" => true}, _c, _me), do: gettext("Message removed by moderation")
  def preview(%{"hidden" => true}, _c, _me), do: gettext("Hidden message")
  def preview(%{"kind" => "system"}, _c, _me), do: gettext("Group activity")

  def preview(message, conversation, me) do
    text =
      case message do
        %{"body" => body} when is_binary(body) -> body
        %{"attachment" => %{"kind" => "image"}} -> gettext("Image")
        %{"attachment" => %{"kind" => "pdf"}} -> gettext("PDF document")
        _ -> ""
      end

    cond do
      message["sender_id"] == me ->
        gettext("You: %{text}", text: text)

      conversation["kind"] == "group" ->
        sender = Enum.find(conversation["members"], &(&1["user"]["id"] == message["sender_id"]))
        gettext("%{name}: %{text}", name: first_name(sender && sender["user"]), text: text)

      true ->
        text
    end
  end

  def file_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: gettext("%{size} MB", size: MysticWeb.Format.decimal(bytes / 1_048_576, 1))

  def file_size(bytes) when is_integer(bytes),
    do: gettext("%{size} KB", size: max(div(bytes + 1023, 1024), 1))

  def file_size(_bytes), do: ""

  ## Avatars

  @doc "Avatar of a conversation: the other member, or the group mark; online dot when it may be shown."
  attr :conversation, :map, required: true
  attr :online, :boolean, default: false

  def conversation_avatar(assigns) do
    ~H"""
    <span class="avatar-wrap">
      <%= if @conversation["kind"] == "group" do %>
        <span class="avatar avatar-md avatar-group" aria-hidden="true">
          <.icon name="hero-user-group" class="size-5" />
        </span>
      <% else %>
        <.avatar user={@conversation["other"] || %{}} />
      <% end %>
      <.online_dot :if={@online} />
    </span>
    """
  end

  def online_dot(assigns) do
    ~H"""
    <span class="presence-dot"><span class="sr-only">{gettext("Online")}</span></span>
    """
  end

  ## Messages

  @doc "One entry of the thread (stream item)."
  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :me, :string, required: true
  attr :group, :boolean, required: true
  attr :people, :map, required: true

  def message(%{message: %{"kind" => "system"}} = assigns) do
    ~H"""
    <li id={@id} class="system-line">
      <span>{system_text(@message, @people)}</span>
      <time datetime={@message["inserted_at"]}>{message_time(@message["inserted_at"])}</time>
    </li>
    """
  end

  def message(%{message: %{"hidden" => true}} = assigns) do
    ~H"""
    <li id={@id} class="bubble bubble-theirs bubble-hidden">
      <p class="bubble-removed">
        <.icon name="hero-eye-slash" class="size-4" /> {gettext("Hidden message")}
      </p>
      <p class="text-xs text-muted">
        {gettext("Messages are hidden between members who have blocked each other.")}
      </p>
    </li>
    """
  end

  def message(assigns) do
    assigns =
      assign(assigns,
        mine: assigns.message["sender_id"] == assigns.me,
        sender: assigns.people[assigns.message["sender_id"]]
      )

    ~H"""
    <li id={@id} class={["bubble", if(@mine, do: "bubble-mine", else: "bubble-theirs")]}>
      <p :if={@group and !@mine} class="bubble-sender">{name(@sender)}</p>
      <p class="sr-only">{if @mine, do: gettext("You"), else: name(@sender)}:</p>
      <p :if={@message["removed"]} class="bubble-removed">
        <.icon name="hero-eye-slash" class="size-4" /> {gettext("Message removed by moderation")}
      </p>
      <.attachment
        :if={@message["attachment"]}
        attachment={@message["attachment"]}
        sender={name(@sender)}
      />
      <p :if={@message["body"]} class="whitespace-pre-wrap break-words">{@message["body"]}</p>
      <time datetime={@message["inserted_at"]} class="bubble-time">
        {message_time(@message["inserted_at"])}
      </time>
      <button
        :if={!@mine and !@message["removed"]}
        type="button"
        phx-click="report_message"
        phx-value-id={@message["id"]}
        class="bubble-action"
        id={"report-#{@message["id"]}"}
      >
        {gettext("Report")}
      </button>
    </li>
    """
  end

  attr :attachment, :map, required: true
  attr :sender, :string, required: true

  def attachment(assigns) do
    ~H"""
    <figure class="attachment" id={"attachment-#{@attachment["id"]}"}>
      <%= cond do %>
        <% !@attachment["available"] -> %>
          <p class="bubble-removed">
            <.icon name="hero-paper-clip" class="size-4" /> {gettext("Attachment deleted")}
          </p>
        <% @attachment["kind"] == "image" -> %>
          <a
            href={~p"/media/attachments/#{@attachment["id"]}"}
            target="_blank"
            rel="noopener"
            class="attachment-image"
          >
            <img
              src={~p"/media/attachments/#{@attachment["id"]}"}
              alt={
                @attachment["alt"] ||
                  gettext("Image shared by %{name}, without a description", name: @sender)
              }
              width={@attachment["width"]}
              height={@attachment["height"]}
              loading="lazy"
              decoding="async"
            />
          </a>
        <% true -> %>
          <a
            href={~p"/media/attachments/#{@attachment["id"]}"}
            download={@attachment["filename"]}
            class="attachment-file"
          >
            <.icon name="hero-document-arrow-down" class="size-6 shrink-0" />
            <span class="min-w-0">
              <span class="block break-all font-medium">{@attachment["filename"]}</span>
              <span class="block text-xs opacity-80">
                {gettext("PDF · %{size} · download", size: file_size(@attachment["byte_size"]))}
              </span>
            </span>
          </a>
      <% end %>
      <figcaption
        :if={@attachment["available"] and @attachment["scan"] == "unscanned"}
        class="attachment-scan"
      >
        <.icon name="hero-shield-exclamation" class="size-4 shrink-0" />
        {gettext("Not scanned by an antivirus")}
      </figcaption>
    </figure>
    """
  end

  ## Details panel

  attr :conversation, :map, required: true
  attr :me, :string, required: true
  attr :friends, :any, required: true
  attr :online, :any, required: true
  attr :rename_form, :any, required: true

  def details_panel(assigns) do
    c = assigns.conversation
    member_ids = MapSet.new(c["members"], & &1["user"]["id"])

    assigns =
      assign(assigns,
        owner: c["owner_id"] == assigns.me,
        group: c["kind"] == "group",
        addable:
          if(is_list(assigns.friends),
            do: Enum.reject(assigns.friends, &MapSet.member?(member_ids, &1["id"])),
            else: []
          )
      )

    ~H"""
    <section id="details-panel" class="details-panel" aria-label={gettext("Conversation details")}>
      <div class="space-y-2">
        <h3 class="text-xl">{gettext("Notifications")}</h3>
        <p id="mute-status" class="text-sm text-muted" role="status">
          <%= cond do %>
            <% !@conversation["muted"] -> %>
              {gettext("Notifications on: this conversation counts in your unread badge.")}
            <% @conversation["muted_until"] -> %>
              {gettext("Muted until %{time}: it stays out of your unread badge.",
                time: message_time(@conversation["muted_until"])
              )}
            <% true -> %>
              {gettext("Muted until you turn it back on: it stays out of your unread badge.")}
          <% end %>
        </p>
        <div class="flex flex-wrap items-end gap-2">
          <.form
            for={%{}}
            as={:mute}
            id="mute-form"
            phx-submit="mute"
            class="flex flex-wrap items-end gap-2"
          >
            <.input
              type="select"
              id="mute-duration"
              name="mute[duration]"
              value="8h"
              label={gettext("Mute for")}
              options={[
                {gettext("1 hour"), "1h"},
                {gettext("8 hours"), "8h"},
                {gettext("24 hours"), "24h"},
                {gettext("Until I turn it back on"), "always"}
              ]}
            />
            <.button type="submit" variant="secondary" id="mute-submit">
              <.icon name="hero-bell-slash" /> {gettext("Mute")}
            </.button>
          </.form>
          <.button
            :if={@conversation["muted"]}
            type="button"
            variant="ghost"
            id="unmute"
            phx-click="unmute"
          >
            <.icon name="hero-bell" /> {gettext("Unmute")}
          </.button>
        </div>
      </div>

      <p
        :if={@conversation["read_receipts"]["enabled"] == false}
        id="receipts-off"
        class="text-sm text-muted"
      >
        {gettext("Your read receipts are off, so you don't see anyone's either.")}
        <.link navigate={~p"/settings/privacy"} class="link">{gettext("Privacy settings")}</.link>
      </p>

      <div :if={@group} class="space-y-3 border-t border-line pt-4">
        <h3 class="text-xl">
          {ngettext("%{count} member", "%{count} members", length(@conversation["members"]))}
        </h3>
        <ul id="group-members" class="divide-y divide-line">
          <li
            :for={member <- @conversation["members"]}
            id={"member-#{member["user"]["id"]}"}
            class="member-row"
          >
            <span class="flex min-w-0 flex-1 items-center gap-3">
              <span class="avatar-wrap">
                <.avatar user={member["user"]} />
                <.online_dot :if={MapSet.member?(@online, member["user"]["id"])} />
              </span>
              <span class="min-w-0">
                <span class="block break-words font-medium text-ink">
                  {name(member["user"])}
                  <span :if={member["user"]["id"] == @me} class="text-muted">
                    ({gettext("you")})
                  </span>
                </span>
                <span class="block break-words text-xs text-muted">
                  @{member["user"]["username"]}
                </span>
              </span>
              <.tag :if={member["role"] == "owner"} kind="info" icon="hero-key">
                {gettext("Owner")}
              </.tag>
            </span>
            <.button
              :if={@owner and member["user"]["id"] != @me}
              type="button"
              variant="ghost"
              id={"remove-member-#{member["user"]["id"]}"}
              phx-click="remove_member"
              phx-value-id={member["user"]["id"]}
              data-confirm={
                gettext("Remove %{name} from the group? They won't see new messages anymore.",
                  name: name(member["user"])
                )
              }
            >
              {gettext("Remove")}
            </.button>
          </li>
        </ul>

        <div :if={@owner} class="grid gap-4 md:grid-cols-2">
          <.form for={@rename_form} id="rename-form" phx-submit="rename" class="space-y-2">
            <.input
              field={@rename_form[:name]}
              label={gettext("Group name")}
              maxlength="60"
              required
            />
            <.button type="submit" variant="secondary" id="rename-submit">
              {gettext("Rename")}
            </.button>
          </.form>
          <.form for={%{}} as={:member} id="add-member-form" phx-submit="add_member" class="space-y-2">
            <%= if @addable == [] do %>
              <p class="text-sm text-muted">
                {gettext("All your friends are already in this group.")}
              </p>
            <% else %>
              <.input
                type="select"
                id="add-member-id"
                name="member[user_id]"
                value=""
                label={gettext("Add a friend")}
                options={for f <- @addable, do: {name(f), f["id"]}}
              />
              <.button type="submit" variant="secondary" id="add-member-submit">
                <.icon name="hero-user-plus" /> {gettext("Add")}
              </.button>
            <% end %>
          </.form>
        </div>

        <.button
          type="button"
          variant="danger"
          id="leave-group"
          phx-click="leave"
          data-confirm={
            if(@owner,
              do:
                gettext(
                  "Leave this group? The longest-standing member becomes its owner; the group is deleted if nobody is left."
                ),
              else: gettext("Leave this group? You won't see its messages anymore.")
            )
          }
        >
          <.icon name="hero-arrow-right-start-on-rectangle" /> {gettext("Leave the group")}
        </.button>
      </div>
    </section>
    """
  end

  ## Group creation

  attr :form, :any, required: true
  attr :friends, :any, required: true
  attr :errors, :list, default: []

  def new_group(assigns) do
    ~H"""
    <div class="space-y-6 overflow-y-auto p-4 md:p-6">
      <.link patch={~p"/messages"} class="link md:hidden">← {gettext("All conversations")}</.link>
      <div class="space-y-1">
        <h2 id="new-group-title" class="text-3xl">{gettext("New group")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "Choose 2 to 19 of your friends. Only friends who accept being added to groups can join."
          )}
        </p>
      </div>
      <%= case @friends do %>
        <% :unavailable -> %>
          <.unavailable id="new-group-unavailable">
            {gettext("Your friends can't be loaded right now.")}
          </.unavailable>
        <% friends when length(friends) < 2 -> %>
          <.notice id="new-group-few-friends" kind="info">
            {gettext("You need at least 2 friends to create a group.")}
            <.link navigate={~p"/friends"} class="link">{gettext("Find friends")}</.link>
          </.notice>
        <% friends -> %>
          <.form for={@form} id="new-group-form" phx-submit="create_group" class="space-y-5">
            <.input
              field={@form[:name]}
              label={gettext("Group name")}
              hint={gettext("1 to 60 characters.")}
              maxlength="60"
              required
            />
            <fieldset
              id="new-group-members"
              class="space-y-3"
              aria-describedby={@errors != [] && "new-group-members-error"}
            >
              <legend class="label">{gettext("Members")}</legend>
              <input type="hidden" name="group[member_ids][]" value="" />
              <div class="choice-grid">
                <label :for={friend <- friends} class="choice" for={"new-group-#{friend["id"]}"}>
                  <input
                    type="checkbox"
                    id={"new-group-#{friend["id"]}"}
                    name="group[member_ids][]"
                    value={friend["id"]}
                    checked={friend["id"] in List.wrap(@form[:member_ids].value)}
                  />
                  <.avatar user={friend} size="sm" />
                  <span class="min-w-0">
                    <span class="block break-words font-medium text-ink">{name(friend)}</span>
                    <span class="block break-words text-xs text-muted">@{friend["username"]}</span>
                  </span>
                </label>
              </div>
              <p :if={@errors != []} id="new-group-members-error" class="field-error">
                <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
                <span>{Enum.map_join(@errors, " · ", &translate_error({&1, []}))}</span>
              </p>
            </fieldset>
            <div class="flex flex-wrap gap-2">
              <.button type="submit" id="create-group" phx-disable-with={gettext("Creating…")}>
                <.icon name="hero-user-group" /> {gettext("Create the group")}
              </.button>
              <.button patch={~p"/messages"} variant="ghost">{gettext("Cancel")}</.button>
            </div>
          </.form>
      <% end %>
    </div>
    """
  end
end
