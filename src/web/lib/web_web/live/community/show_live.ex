defmodule MysticWeb.Community.ShowLive do
  @moduledoc "A discussion and its replies, with the actions of members and moderators."
  use MysticWeb, :live_view
  import MysticWeb.CommunityComponents

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    socket =
      assign(socket,
        slug: slug,
        page: 1,
        notices: [],
        toast_except: [{"community", "discussion", slug}],
        reporting: nil,
        moderating: nil,
        editing: nil,
        edit_form: nil,
        blocked_now: MapSet.new(),
        reply_form: reply_form(""),
        replies: %{"entries" => [], "page" => 1, "total_pages" => 1, "total" => 0},
        categories: []
      )

    {:ok, if(staff?(socket.assigns.current_user), do: load_categories(socket), else: socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, page: page_number(params["page"]))

    case fetch(socket) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, message} ->
        {:noreply,
         assign(socket, discussion: {:unavailable, message}, page_title: gettext("Discussion"))}

      :not_found ->
        raise MysticWeb.NotFoundError
    end
  end

  defp page_number(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 1 -> n
      _ -> 1
    end
  end

  defp load_categories(socket) do
    case Api.get(socket, :community, "/api/categories") do
      {:ok, %{"categories" => list}} when is_list(list) -> assign(socket, categories: list)
      _ -> socket
    end
  end

  defp fetch(socket) do
    case Api.get(socket, :community, "/api/discussions/:slug",
           path_params: [slug: socket.assigns.slug],
           params: if(socket.assigns.page > 1, do: [page: socket.assigns.page], else: [])
         ) do
      {:ok,
       %{
         "discussion" => %{"id" => _} = discussion,
         "replies" => %{"entries" => entries} = replies
       }}
      when is_list(entries) ->
        # Defence in depth right after a block: the service filters too (its cache is invalidated by social).
        entries =
          Enum.reject(entries, &MapSet.member?(socket.assigns.blocked_now, &1["author"]["id"]))

        {:ok,
         assign(socket,
           discussion: discussion,
           replies: %{replies | "entries" => entries},
           page_title: discussion["title"]
         )}

      {:error, {:http, 404, _}} ->
        :not_found

      error ->
        {:error, community_error(error)}
    end
  end

  defp reload(socket) do
    case fetch(socket) do
      {:ok, socket} ->
        socket

      {:error, message} ->
        put_flash(socket, :error, message)

      :not_found ->
        socket
        |> put_flash(:error, gettext("This discussion is no longer available."))
        |> push_navigate(to: ~p"/community")
    end
  end

  defp after_action({:ok, _}, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> reload()}

  defp after_action(error, socket, _message),
    do: {:noreply, put_flash(socket, :error, community_error(error))}

  defp reply_form(body, errors \\ []), do: to_form(%{"body" => body}, as: :reply, errors: errors)

  defp replies_path(slug, page) when page > 1, do: ~p"/community/discussions/#{slug}?page=#{page}"
  defp replies_path(slug, _page), do: ~p"/community/discussions/#{slug}"

  ## Events

  @impl true
  def handle_event("reply", %{"reply" => %{"body" => body}}, socket) do
    case Api.post(socket, :community, "/api/discussions/:slug/replies",
           path_params: [slug: socket.assigns.slug],
           json: %{body: body}
         ) do
      {:ok, %{"reply" => _}} ->
        socket =
          socket
          |> assign(reply_form: reply_form(""))
          |> put_flash(:info, gettext("Reply posted."))
          |> reload()

        {:noreply, to_latest_replies(socket)}

      {:error, {:http, 422, _}} = error ->
        {:noreply, assign(socket, reply_form: reply_form(body, Api.form_errors(error, [:body])))}

      error ->
        {:noreply,
         socket
         |> assign(reply_form: reply_form(body))
         |> put_flash(:error, community_error(error))}
    end
  end

  def handle_event("vote", %{"type" => type, "id" => id}, socket) do
    {path, path_params, post} =
      if type == "discussion",
        do:
          {"/api/discussions/:slug/vote", [slug: socket.assigns.slug], socket.assigns.discussion},
        else: {"/api/replies/:id/vote", [id: id], find_reply(socket, id)}

    result =
      if post["voted"],
        do: Api.delete(socket, :community, path, path_params: path_params),
        else: Api.put(socket, :community, path, path_params: path_params)

    case result do
      {:ok, %{"voted" => voted, "helpful_count" => count}} ->
        {:noreply, update_post(socket, type, id, %{"voted" => voted, "helpful_count" => count})}

      error ->
        {:noreply, put_flash(socket, :error, community_error(error))}
    end
  end

  def handle_event(action, _params, socket) when action in ~w(follow unfollow) do
    request = if action == "follow", do: &Api.put/4, else: &Api.delete/4

    case request.(socket, :community, "/api/discussions/:slug/follow",
           path_params: [slug: socket.assigns.slug]
         ) do
      {:ok, %{"following" => following}} ->
        message =
          if following,
            do: gettext("You'll be notified of new replies."),
            else: gettext("You won't be notified anymore.")

        {:noreply,
         socket
         |> update(:discussion, &Map.put(&1, "following", following))
         |> put_flash(:info, message)}

      error ->
        {:noreply, put_flash(socket, :error, community_error(error))}
    end
  end

  def handle_event("solution", %{"id" => reply_id}, socket) do
    Api.put(socket, :community, "/api/discussions/:slug/solution",
      path_params: [slug: socket.assigns.slug],
      json: %{reply_id: reply_id}
    )
    |> after_action(socket, gettext("Marked as the solution."))
  end

  def handle_event("unsolve", _params, socket) do
    Api.delete(socket, :community, "/api/discussions/:slug/solution",
      path_params: [slug: socket.assigns.slug]
    )
    |> after_action(socket, gettext("The discussion has no solution anymore."))
  end

  def handle_event("edit_reply", %{"id" => id}, socket) do
    case find_reply(socket, id) do
      %{"body" => body} ->
        {:noreply, assign(socket, editing: id, edit_form: to_form(%{"body" => body}, as: :edit))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event(
        "save_reply",
        %{"edit" => %{"body" => body}},
        %{assigns: %{editing: id}} = socket
      )
      when is_binary(id) do
    case Api.patch(socket, :community, "/api/replies/:id",
           path_params: [id: id],
           json: %{body: body}
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(editing: nil) |> put_flash(:info, gettext("Reply updated.")) |> reload()}

      {:error, {:http, 422, _}} = error ->
        errors = Api.form_errors(error, [:body])

        {:noreply,
         assign(socket, edit_form: to_form(%{"body" => body}, as: :edit, errors: errors))}

      error ->
        {:noreply,
         socket |> assign(editing: nil) |> put_flash(:error, community_error(error)) |> reload()}
    end
  end

  def handle_event("delete_reply", %{"id" => id}, socket) do
    Api.delete(socket, :community, "/api/replies/:id", path_params: [id: id])
    |> after_action(socket, gettext("Reply deleted."))
  end

  def handle_event("delete_discussion", _params, socket) do
    case Api.delete(socket, :community, "/api/discussions/:slug",
           path_params: [slug: socket.assigns.slug]
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Discussion deleted."))
         |> push_navigate(to: ~p"/community")}

      error ->
        {:noreply, put_flash(socket, :error, community_error(error))}
    end
  end

  def handle_event("report", %{"type" => type, "id" => id}, socket)
      when type in ~w(discussion reply),
      do: {:noreply, assign(socket, reporting: %{type: type, id: id}, moderating: nil)}

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: nil)}

  def handle_event(
        "submit_report",
        %{"report" => params},
        %{assigns: %{reporting: %{} = target}} = socket
      ) do
    body = %{
      target_type: target.type,
      target_id: target.id,
      reason: params["reason"],
      details: params["details"]
    }

    case Api.post(socket, :community, "/api/reports", json: body) do
      {:ok, _} ->
        message = gettext("Report sent. Thank you — the moderators will review it.")
        {:noreply, socket |> assign(reporting: nil) |> put_flash(:info, message)}

      error ->
        {:noreply, socket |> assign(reporting: nil) |> put_flash(:error, community_error(error))}
    end
  end

  def handle_event("block", %{"id" => user_id}, socket) do
    case Api.post(socket, :social, "/api/blocks", json: %{user_id: user_id}) do
      {:ok, _} ->
        message = gettext("Member blocked. You won't see their posts anymore.")
        socket = put_flash(socket, :info, message)

        if user_id == socket.assigns.discussion["author"]["id"],
          do: {:noreply, push_navigate(socket, to: ~p"/community")},
          else: {:noreply, socket |> update(:blocked_now, &MapSet.put(&1, user_id)) |> reload()}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("moderate", %{"type" => type, "id" => id, "action" => action}, socket)
      when action in ~w(hide remove),
      do:
        {:noreply,
         assign(socket, moderating: %{type: type, id: id, action: action}, reporting: nil)}

  def handle_event("moderate", %{"type" => type, "id" => id, "action" => action}, socket),
    do: moderate(socket, type, id, %{action: action})

  def handle_event(
        "submit_moderation",
        %{"moderation" => %{"reason" => reason}},
        %{assigns: %{moderating: %{} = target}} = socket
      ) do
    socket
    |> assign(moderating: nil)
    |> moderate(target.type, target.id, %{action: target.action, reason: reason})
  end

  def handle_event("cancel_moderation", _params, socket),
    do: {:noreply, assign(socket, moderating: nil)}

  def handle_event("move", %{"move" => %{"category" => category}}, socket) do
    moderate(socket, "discussion", socket.assigns.discussion["id"], %{
      action: "move",
      category: category
    })
  end

  def handle_event("dismiss_notice", %{"slug" => slug}, socket),
    do: {:noreply, update(socket, :notices, &Enum.reject(&1, fn n -> n.slug == slug end))}

  defp moderate(socket, type, id, body) do
    path =
      if type == "discussion",
        do: "/api/moderation/discussions/:id",
        else: "/api/moderation/replies/:id"

    Api.post(socket, :community, path, path_params: [id: id], json: body)
    |> after_action(socket, gettext("Moderation action recorded."))
  end

  defp find_reply(socket, id), do: Enum.find(socket.assigns.replies["entries"], &(&1["id"] == id))

  defp update_post(socket, "discussion", _id, changes),
    do: update(socket, :discussion, &Map.merge(&1, changes))

  defp update_post(socket, _reply, id, changes) do
    update(socket, :replies, fn replies ->
      entries =
        Enum.map(replies["entries"], &if(&1["id"] == id, do: Map.merge(&1, changes), else: &1))

      %{replies | "entries" => entries}
    end)
  end

  defp to_latest_replies(%{assigns: %{discussion: %{}, replies: replies, page: page}} = socket) do
    last = replies["total_pages"] || 1

    if last > page,
      do: push_patch(socket, to: replies_path(socket.assigns.slug, last)),
      else: socket
  end

  defp to_latest_replies(socket), do: socket

  @impl true
  def handle_info({:community_reply, slug, title}, %{assigns: %{slug: slug}} = socket) do
    socket = update(socket, :notices, &push_notice(&1, slug, title))
    {:noreply, reload(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  defp mine?(post, user), do: user != nil and post["author"]["id"] == user["id"]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :staff, staff?(assigns.current_user))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      current_path={@current_path}
      active={:community}
    >
      <div class="community-page space-y-6">
        <div>
          <nav aria-label={gettext("Breadcrumb")} class="breadcrumb">
            <.link navigate={~p"/community"}>{gettext("Community")}</.link>
            <span :if={is_map(@discussion)} aria-hidden="true">/</span>
            <.link
              :if={is_map(@discussion)}
              navigate={~p"/community?#{%{category: @discussion["category"]["slug"]}}"}
            >
              {category_name(@discussion["category"])}
            </.link>
          </nav>

          <.follow_banner
            notices={@notices}
            last_page={is_map(@discussion) && replies_path(@slug, @replies["total_pages"] || 1)}
          />
        </div>

        <%= case @discussion do %>
          <% {:unavailable, message} -> %>
            <.notice
              id="discussion-unavailable"
              kind="warning"
              title={gettext("Temporarily unavailable")}
            >
              {message}
            </.notice>
          <% discussion -> %>
            <article id="discussion" class="post post-discussion" aria-labelledby="discussion-title">
              <div class="flex flex-wrap items-center gap-2">
                <.post_tags post={discussion} />
              </div>
              <h1 id="discussion-title" class="break-words text-4xl md:text-5xl">
                {discussion["title"]}
              </h1>
              <.byline post={discussion} />
              <.notice
                :if={status_label(discussion["status"])}
                id="discussion-status"
                kind="warning"
                title={status_label(discussion["status"])}
              >
                <span :if={discussion["moderation_reason"]}>
                  {gettext("Reason: %{reason}", reason: discussion["moderation_reason"])}
                </span>
              </.notice>
              <.post_body id="discussion-body" text={discussion["body"]} />

              <div class="post-actions" id="discussion-actions">
                <.vote_button type="discussion" post={discussion} current_user={@current_user} />
                <%= if @current_user do %>
                  <.button
                    :if={!discussion["following"]}
                    phx-click="follow"
                    variant="secondary"
                    id="follow"
                  >
                    <.icon name="hero-bell" /> {gettext("Follow")}
                  </.button>
                  <.button
                    :if={discussion["following"]}
                    phx-click="unfollow"
                    variant="secondary"
                    id="unfollow"
                    aria-pressed="true"
                  >
                    <.icon name="hero-bell-slash" /> {gettext("Unfollow")}
                  </.button>
                  <.button
                    :if={discussion["can_edit"]}
                    navigate={~p"/community/discussions/#{@slug}/edit"}
                    variant="ghost"
                    id="edit-discussion"
                  >
                    <.icon name="hero-pencil-square" /> {gettext("Edit")}
                  </.button>
                  <.button
                    :if={mine?(discussion, @current_user)}
                    phx-click="delete_discussion"
                    variant="ghost"
                    id="delete-discussion"
                    data-confirm={
                      gettext("Delete this discussion? Its replies will disappear with it.")
                    }
                  >
                    <.icon name="hero-trash" /> {gettext("Delete")}
                  </.button>
                  <.member_tools
                    :if={!mine?(discussion, @current_user)}
                    type="discussion"
                    post={discussion}
                  />
                <% end %>
              </div>
            </article>

            <section
              :if={@staff}
              id="moderation-tools"
              class="card space-y-4"
              aria-labelledby="moderation-tools-title"
            >
              <h2 id="moderation-tools-title" class="text-2xl">{gettext("Moderation")}</h2>
              <div class="post-actions">
                <.button
                  phx-click="moderate"
                  phx-value-type="discussion"
                  phx-value-id={discussion["id"]}
                  phx-value-action={if discussion["pinned"], do: "unpin", else: "pin"}
                  variant="secondary"
                  id="mod-pin"
                >
                  <.icon name="hero-bookmark" />
                  {if discussion["pinned"], do: gettext("Unpin"), else: gettext("Pin")}
                </.button>
                <.button
                  phx-click="moderate"
                  phx-value-type="discussion"
                  phx-value-id={discussion["id"]}
                  phx-value-action={if discussion["locked"], do: "unlock", else: "lock"}
                  variant="secondary"
                  id="mod-lock"
                >
                  <.icon name="hero-lock-closed" />
                  {if discussion["locked"], do: gettext("Unlock"), else: gettext("Lock")}
                </.button>
                <.moderation_buttons type="discussion" post={discussion} />
              </div>
              <.form
                :if={@categories != [] and discussion["status"] != "deleted"}
                for={%{}}
                as={:move}
                id="move-form"
                phx-submit="move"
                class="flex flex-wrap items-end gap-3"
              >
                <div class="min-w-48 flex-1 sm:flex-none">
                  <.input
                    id="move-category"
                    name="move[category]"
                    type="select"
                    value={discussion["category"]["slug"]}
                    label={gettext("Move to category")}
                    options={Enum.map(@categories, &{category_name(&1), &1["slug"]})}
                  />
                </div>
                <.button type="submit" variant="secondary">{gettext("Move")}</.button>
              </.form>
            </section>

            <.moderation_form :if={@moderating} target={@moderating} />
            <.report_form :if={@reporting} target={@reporting} />

            <section id="replies" class="space-y-4" aria-labelledby="replies-title">
              <h2 id="replies-title" class="text-3xl">
                {ngettext("%{count} reply", "%{count} replies", @replies["total"] || 0)}
              </h2>
              <p :if={@replies["entries"] == []} id="replies-empty" class="text-muted">
                {gettext("No reply yet.")}
              </p>
              <ol class="space-y-4">
                <li
                  :for={reply <- @replies["entries"]}
                  id={"reply-#{reply["id"]}"}
                  class={["post post-reply", reply["solution"] && "is-solution"]}
                >
                  <div class="flex flex-wrap items-center gap-2">
                    <.tag :if={reply["solution"]} kind="success" icon="hero-check-circle">
                      {gettext("Solution")}
                    </.tag>
                    <.post_tags post={reply} />
                  </div>
                  <.byline post={reply} />
                  <p
                    :if={status_label(reply["status"]) && reply["moderation_reason"]}
                    class="text-sm text-muted"
                  >
                    {gettext("Reason: %{reason}", reason: reply["moderation_reason"])}
                  </p>
                  <%= if @editing == reply["id"] do %>
                    <.form
                      for={@edit_form}
                      id="edit-reply-form"
                      phx-submit="save_reply"
                      class="space-y-3"
                    >
                      <.input
                        field={@edit_form[:body]}
                        type="textarea"
                        rows="4"
                        maxlength="5000"
                        label={gettext("Edit your reply")}
                      />
                      <div class="flex flex-wrap gap-2">
                        <.button type="submit">{gettext("Save")}</.button>
                        <.button type="button" phx-click="cancel_edit" variant="ghost">
                          {gettext("Cancel")}
                        </.button>
                      </div>
                    </.form>
                  <% else %>
                    <.post_body text={reply["body"]} />
                  <% end %>
                  <div class="post-actions">
                    <.vote_button type="reply" post={reply} current_user={@current_user} />
                    <%= if @current_user do %>
                      <.button
                        :if={
                          mine?(discussion, @current_user) and discussion["status"] == "visible" and
                            reply["status"] == "visible"
                        }
                        phx-click={if reply["solution"], do: "unsolve", else: "solution"}
                        phx-value-id={reply["id"]}
                        variant="secondary"
                        aria-pressed={to_string(reply["solution"] == true)}
                        id={"solution-#{reply["id"]}"}
                      >
                        <.icon name="hero-check-circle" />
                        {if reply["solution"],
                          do: gettext("Unmark solution"),
                          else: gettext("Mark as solution")}
                      </.button>
                      <.button
                        :if={reply["can_edit"] and @editing != reply["id"]}
                        phx-click="edit_reply"
                        phx-value-id={reply["id"]}
                        variant="ghost"
                        id={"edit-#{reply["id"]}"}
                      >
                        <.icon name="hero-pencil-square" /> {gettext("Edit")}
                      </.button>
                      <.button
                        :if={mine?(reply, @current_user)}
                        phx-click="delete_reply"
                        phx-value-id={reply["id"]}
                        variant="ghost"
                        id={"delete-#{reply["id"]}"}
                        data-confirm={gettext("Delete this reply?")}
                      >
                        <.icon name="hero-trash" /> {gettext("Delete")}
                      </.button>
                      <.member_tools :if={!mine?(reply, @current_user)} type="reply" post={reply} />
                      <.moderation_buttons :if={@staff} type="reply" post={reply} />
                    <% end %>
                  </div>
                </li>
              </ol>
              <.pager
                id="replies-pagination"
                page={@replies["page"] || 1}
                total_pages={@replies["total_pages"] || 1}
                path={&replies_path(@slug, &1)}
              />
            </section>

            <section id="composer" aria-labelledby="composer-title" class="card space-y-4">
              <h2 id="composer-title" class="text-2xl">{gettext("Your reply")}</h2>
              <%= cond do %>
                <% !@current_user -> %>
                  <p id="login-to-reply">
                    <.link href={~p"/login"} class="link">{gettext("Log in")}</.link>
                    {gettext("to reply, vote or follow this discussion.")}
                  </p>
                <% discussion["status"] != "visible" -> %>
                  <p class="text-muted">
                    {gettext("Replies are closed while this discussion is moderated.")}
                  </p>
                <% discussion["locked"] and !@staff -> %>
                  <.notice id="discussion-locked" kind="info">
                    {gettext("This discussion is locked: new replies are closed.")}
                  </.notice>
                <% true -> %>
                  <.form for={@reply_form} id="reply-form" phx-submit="reply" class="space-y-3">
                    <.input
                      field={@reply_form[:body]}
                      type="textarea"
                      rows="5"
                      maxlength="5000"
                      required
                      label={gettext("Write your reply")}
                      hint={
                        gettext(
                          "Plain text: HTML isn't interpreted, links starting with http:// or https:// become clickable."
                        )
                      }
                    />
                    <.button type="submit" id="post-reply" phx-disable-with={gettext("Posting…")}>
                      <.icon name="hero-paper-airplane" /> {gettext("Post reply")}
                    </.button>
                  </.form>
              <% end %>
            </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :post, :map, required: true

  defp byline(assigns) do
    ~H"""
    <p class="meta">
      <.identity user={@post["author"]} />
      <span aria-hidden="true">·</span>
      <time datetime={@post["inserted_at"]}>{message_time(@post["inserted_at"])}</time>
      <span :if={@post["edited_at"]}>· {gettext("edited")}</span>
    </p>
    """
  end

  attr :type, :string, required: true
  attr :post, :map, required: true

  # Report and block, for posts of other members.
  defp member_tools(assigns) do
    ~H"""
    <.button
      :if={@post["status"] == "visible"}
      phx-click="report"
      phx-value-type={@type}
      phx-value-id={@post["id"]}
      variant="ghost"
      id={"report-#{@type}-#{@post["id"]}"}
    >
      <.icon name="hero-flag" /> {gettext("Report")}
    </.button>
    <.button
      :if={@post["author"]["id"]}
      phx-click="block"
      phx-value-id={@post["author"]["id"]}
      variant="ghost"
      id={"block-#{@type}-#{@post["id"]}"}
      data-confirm={
        gettext("Block %{name}? You won't see each other's posts anymore.",
          name: author_name(@post["author"])
        )
      }
    >
      <.icon name="hero-no-symbol" /> {gettext("Block author")}
    </.button>
    """
  end

  attr :type, :string, required: true
  attr :post, :map, required: true

  defp moderation_buttons(assigns) do
    ~H"""
    <%= if @post["status"] in ["hidden", "removed"] do %>
      <.button
        phx-click="moderate"
        phx-value-type={@type}
        phx-value-id={@post["id"]}
        phx-value-action="restore"
        variant="secondary"
        id={"mod-restore-#{@post["id"]}"}
      >
        <.icon name="hero-arrow-uturn-left" /> {gettext("Restore")}
      </.button>
    <% end %>
    <%= if @post["status"] != "deleted" do %>
      <.button
        :if={@post["status"] != "hidden"}
        phx-click="moderate"
        phx-value-type={@type}
        phx-value-id={@post["id"]}
        phx-value-action="hide"
        variant="danger"
        id={"mod-hide-#{@post["id"]}"}
      >
        <.icon name="hero-eye-slash" /> {gettext("Hide")}
      </.button>
      <.button
        :if={@post["status"] != "removed"}
        phx-click="moderate"
        phx-value-type={@type}
        phx-value-id={@post["id"]}
        phx-value-action="remove"
        variant="danger"
        id={"mod-remove-#{@post["id"]}"}
      >
        <.icon name="hero-x-circle" /> {gettext("Remove")}
      </.button>
    <% end %>
    """
  end
end
