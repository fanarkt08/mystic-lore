defmodule MysticWeb.CommunityComponents do
  @moduledoc """
  Forum components. User content is never rendered as HTML: only `http(s)://` URLs with a host become links.
  """
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  use Phoenix.VerifiedRoutes, endpoint: MysticWeb.Endpoint, router: MysticWeb.Router
  import MysticWeb.CoreComponents
  import MysticWeb.MysticComponents, only: [tag: 1, identity: 1]
  import MysticWeb.Format, only: [message_time: 1]
  alias MysticWeb.Api

  ## Plain text with safe links

  @url ~r{https?://[^\s<>"'`]+}iu

  @doc "Splits a text into `{:text, string}` and `{:link, url}` (http and https URLs with a host only)."
  def segments(text) when is_binary(text) do
    @url
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.flat_map(fn part ->
      if Regex.match?(~r{\Ahttps?://}i, part), do: link_parts(part), else: [{:text, part}]
    end)
    |> Enum.reduce([], fn
      {:text, text}, [{:text, previous} | rest] -> [{:text, previous <> text} | rest]
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
  end

  def segments(_text), do: []

  # Trailing punctuation ends the sentence, not the URL: "see https://example.com/a." links ".../a".
  defp link_parts(candidate) do
    url = String.replace(candidate, ~r/[.,;:!?)\]}*]+\z/u, "")
    tail = binary_part(candidate, byte_size(url), byte_size(candidate) - byte_size(url))

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        [{:link, url} | if(tail == "", do: [], else: [{:text, tail}])]

      _ ->
        [{:text, candidate}]
    end
  end

  attr :text, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  @doc "A post body: escaped plain text (line breaks kept) with safe autolinks."
  def post_body(assigns) do
    ~H"""
    <div id={@id} class={["post-body", @class]} phx-no-format><.segment :for={segment <- segments(@text)} segment={segment} /></div>
    """
  end

  defp segment(%{segment: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  defp segment(%{segment: {:link, url}} = assigns) do
    assigns = assign(assigns, :url, url)

    ~H|<a href={@url} rel="nofollow ugc noopener noreferrer" target="_blank" class="link break-all">{@url}</a>|
  end

  ## Labels

  @doc "Category name (translated for the known categories, as given by the service otherwise)."
  def category_name(%{"slug" => "announcements"}), do: gettext("Announcements")
  def category_name(%{"slug" => "help-questions"}), do: gettext("Help & Questions")
  def category_name(%{"slug" => "showcase"}), do: gettext("Showcase")
  def category_name(%{"slug" => "study-groups"}), do: gettext("Study Groups")
  def category_name(%{"slug" => "off-topic"}), do: gettext("Off-topic")
  def category_name(%{"name" => name}) when is_binary(name), do: name
  def category_name(_category), do: gettext("Forum")

  def author_name(%{"display_name" => name}) when is_binary(name), do: name
  def author_name(%{"username" => name}) when is_binary(name), do: name
  def author_name(_author), do: gettext("Unknown member")

  def status_label("hidden"), do: gettext("Hidden by moderators")
  def status_label("removed"), do: gettext("Removed by moderators")
  def status_label("deleted"), do: gettext("Deleted by its author")
  def status_label(_status), do: nil

  def staff?(%{"role" => role}), do: role in ~w(moderator admin)
  def staff?(_user), do: false

  @doc "A clear message for an error of the community service (specific codes first)."
  def community_error({:error, {:http, 429, _}}),
    do: gettext("You're posting too fast: up to 10 posts every 10 minutes. Please wait a little.")

  def community_error({:error, {:http, 503, %{"error" => "blocks_unavailable"}}}),
    do:
      gettext(
        "The forum can't check your blocked members right now, so posts stay hidden for your safety. Please try again in a moment."
      )

  def community_error({:error, {:http, 503, %{"error" => "roles_unavailable"}}}),
    do: gettext("Moderator rights can't be verified right now. Please try again in a moment.")

  def community_error(result) do
    case Api.error_code(result) do
      "locked" -> gettext("This discussion is locked: new replies are closed.")
      "edit_window_expired" -> gettext("Posts can only be edited during the first 30 minutes.")
      "own_content" -> gettext("You can't do that on your own post.")
      "already_reported" -> gettext("You already reported this. The moderators will review it.")
      "conflict" -> gettext("This content can't be changed that way anymore. Refresh the page.")
      _ -> Api.error_message(result)
    end
  end

  ## Discussions

  attr :discussion, :map, required: true
  attr :id, :string, required: true

  @doc "Discussion summary: a card on mobile, a row on wider screens (the whole item is one link)."
  def discussion_card(assigns) do
    ~H"""
    <article id={@id} class="discussion-card">
      <div class="min-w-0 flex-1 space-y-2">
        <div class="flex flex-wrap items-center gap-2">
          <.tag kind="info">{category_name(@discussion["category"])}</.tag>
          <.post_tags post={@discussion} />
        </div>
        <h2 class="discussion-card-title">
          <.link navigate={~p"/community/discussions/#{@discussion["slug"]}"} class="card-link">
            {@discussion["title"]}
          </.link>
        </h2>
        <p :if={@discussion["excerpt"]} class="discussion-card-excerpt">{@discussion["excerpt"]}</p>
        <p class="meta">
          <.identity user={@discussion["author"]} />
          <span aria-hidden="true">·</span>
          <time datetime={@discussion["last_activity_at"]}>
            {gettext("active %{time}", time: message_time(@discussion["last_activity_at"]))}
          </time>
        </p>
      </div>
      <dl class="discussion-card-stats">
        <div>
          <dt>{gettext("Replies")}</dt>
          <dd>{@discussion["reply_count"] || 0}</dd>
        </div>
        <div>
          <dt>{gettext("Helpful")}</dt>
          <dd>{@discussion["helpful_count"] || 0}</dd>
        </div>
      </dl>
    </article>
    """
  end

  attr :post, :map, required: true

  @doc "Words (never colour only) for pinned, locked, solved, followed and moderated posts."
  def post_tags(assigns) do
    ~H"""
    <.tag :if={@post["pinned"]} kind="premium" icon="hero-bookmark">{gettext("Pinned")}</.tag>
    <.tag :if={@post["locked"]} icon="hero-lock-closed">{gettext("Locked")}</.tag>
    <.tag :if={@post["solved"]} kind="success" icon="hero-check-circle">{gettext("Solved")}</.tag>
    <.tag :if={@post["following"]} kind="info" icon="hero-bell">{gettext("Following")}</.tag>
    <.tag :if={status_label(@post["status"])} kind="danger" icon="hero-eye-slash">
      {status_label(@post["status"])}
    </.tag>
    """
  end

  attr :type, :string, required: true, values: ~w(discussion reply)
  attr :post, :map, required: true
  attr :current_user, :map, default: nil

  @doc "Helpful vote toggle (aria-pressed); a plain count for visitors, authors and moderated posts."
  def vote_button(assigns) do
    assigns =
      assign(assigns,
        votable:
          assigns.current_user != nil and assigns.post["status"] == "visible" and
            assigns.post["author"]["id"] != assigns.current_user["id"]
      )

    ~H"""
    <button
      :if={@votable}
      type="button"
      id={"vote-#{@type}-#{@post["id"]}"}
      class={["btn btn-secondary vote-button", @post["voted"] && "is-voted"]}
      phx-click="vote"
      phx-value-type={@type}
      phx-value-id={@post["id"]}
      aria-pressed={to_string(@post["voted"] == true)}
    >
      <.icon name="hero-hand-thumb-up" />
      <span>{gettext("Helpful")}</span>
      <span class="vote-count">{@post["helpful_count"]}</span>
    </button>
    <p :if={!@votable} class="meta" id={"votes-#{@type}-#{@post["id"]}"}>
      <.icon name="hero-hand-thumb-up" class="size-4" />
      {ngettext(
        "%{count} member found this helpful",
        "%{count} members found this helpful",
        @post["helpful_count"] || 0
      )}
    </p>
    """
  end

  ## Live banner

  @doc "Adds the notice of a new reply in the discussion on screen (one at a time)."
  def push_notice(_notices, slug, title), do: [%{slug: slug, title: title}]

  attr :notices, :list, required: true
  attr :last_page, :string, default: nil, doc: "path to the latest replies of the discussion"

  @doc "Polite live region announcing a new reply in the discussion on screen."
  def follow_banner(assigns) do
    ~H"""
    <div id="community-live" class="community-live" role="status" aria-live="polite">
      <div :for={notice <- @notices} id={"notice-#{notice.slug}"} class="community-notice">
        <.icon name="hero-bell-alert" class="size-5 shrink-0 text-reward" />
        <p class="min-w-0 flex-1">{gettext("New reply in this discussion.")}</p>
        <.link
          navigate={@last_page || ~p"/community/discussions/#{notice.slug}"}
          class="link text-sm"
        >
          {gettext("Read")}
        </.link>
        <button
          type="button"
          class="toast-close"
          phx-click="dismiss_notice"
          phx-value-slug={notice.slug}
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  ## Forms

  attr :target, :map, required: true, doc: "%{type: \"discussion\" | \"reply\", id: id}"

  @doc "Report form for a discussion or a reply."
  def report_form(assigns) do
    ~H"""
    <section
      id="report-panel"
      class="card space-y-4 border-danger/40"
      aria-labelledby="report-title"
      phx-hook="ReturnFocus"
      data-return-focus
      phx-mounted={Phoenix.LiveView.JS.focus_first(to: "#report-panel")}
    >
      <h2 id="report-title" class="text-2xl">
        {if @target.type == "discussion",
          do: gettext("Report this discussion"),
          else: gettext("Report this reply")}
      </h2>
      <p class="text-sm text-muted">
        {gettext("Reports are confidential. The moderators see a copy of the post as it is now.")}
      </p>
      <.form for={%{}} as={:report} id="report-form" phx-submit="submit_report" class="space-y-4">
        <.input
          id="report-reason"
          name="report[reason]"
          value="spam"
          type="select"
          label={gettext("Reason")}
          options={[
            {gettext("Spam"), "spam"},
            {gettext("Harassment"), "harassment"},
            {gettext("Inappropriate content"), "inappropriate"},
            {gettext("Other"), "other"}
          ]}
        />
        <.input
          id="report-details"
          name="report[details]"
          value=""
          type="textarea"
          rows="3"
          maxlength="2000"
          label={gettext("Details (optional)")}
        />
        <div class="flex flex-wrap gap-2">
          <.button type="submit" variant="danger">{gettext("Send report")}</.button>
          <.button type="button" phx-click="cancel_report" variant="ghost">{gettext("Cancel")}</.button>
        </div>
      </.form>
    </section>
    """
  end

  attr :target, :map, required: true, doc: "%{type:, id:, action: \"hide\" | \"remove\"}"

  @doc "Mandatory reason before hiding or removing a post."
  def moderation_form(assigns) do
    ~H"""
    <section
      id="moderation-panel"
      class="card space-y-4"
      aria-labelledby="moderation-title"
      phx-mounted={Phoenix.LiveView.JS.focus_first(to: "#moderation-panel")}
    >
      <h2 id="moderation-title" class="text-2xl">
        {if @target.action == "hide",
          do: gettext("Hide this post"),
          else: gettext("Remove this post")}
      </h2>
      <.form
        for={%{}}
        as={:moderation}
        id="moderation-form"
        phx-submit="submit_moderation"
        class="space-y-4"
      >
        <.input
          id="moderation-reason"
          name="moderation[reason]"
          value=""
          type="text"
          maxlength="500"
          required
          label={gettext("Reason (shown to the author, kept in the moderation log)")}
        />
        <div class="flex flex-wrap gap-2">
          <.button type="submit" variant="danger">{gettext("Confirm")}</.button>
          <.button type="button" phx-click="cancel_moderation" variant="ghost">{gettext("Cancel")}</.button>
        </div>
      </.form>
    </section>
    """
  end

  ## Pagination

  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :path, :any, required: true, doc: "fn page -> path"

  def pager(assigns) do
    ~H"""
    <nav
      :if={@total_pages > 1}
      id={@id}
      class="flex flex-wrap items-center justify-between gap-3"
      aria-label={gettext("Pagination")}
    >
      <.button :if={@page > 1} patch={@path.(@page - 1)} variant="secondary" id={"#{@id}-prev"}>
        <.icon name="hero-arrow-left" /> {gettext("Previous")}
      </.button>
      <span :if={@page <= 1}></span>
      <p class="text-sm text-muted" aria-current="page">
        {gettext("Page %{page} of %{total}", page: @page, total: @total_pages)}
      </p>
      <.button
        :if={@page < @total_pages}
        patch={@path.(@page + 1)}
        variant="secondary"
        id={"#{@id}-next"}
      >
        {gettext("Next")} <.icon name="hero-arrow-right" />
      </.button>
      <span :if={@page >= @total_pages}></span>
    </nav>
    """
  end
end
