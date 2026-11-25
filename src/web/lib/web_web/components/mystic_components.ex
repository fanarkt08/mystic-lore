defmodule MysticWeb.MysticComponents do
  @moduledoc "Domain components: cover art, adventure cards, tags, progress, charts, avatars, plans."
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: MysticWeb.Endpoint,
    router: MysticWeb.Router,
    statics: MysticWeb.static_paths()

  import MysticWeb.CoreComponents
  import MysticWeb.Format

  @covers ~w(forest observatory alchemy archive hero)

  # Illustrations des maquettes Figma découpées en WebP : clé de couverture => {largeur, hauteur} en pixels.
  @images %{
    "hero" => {700, 560},
    "forest" => {610, 342},
    "observatory" => {392, 180},
    "archive" => {392, 180},
    "alchemy" => {414, 134}
  }

  @doc """
  Cover illustration: the image of the cover key (local WebP, lazy-loaded unless `loading="eager"`), or a local
  CSS gradient for a cover without image (adventures made in the studio).
  """
  attr :cover, :string, default: nil
  attr :class, :any, default: nil
  attr :label, :boolean, default: true, doc: "kept for compatibility: no visible label anymore"
  attr :loading, :string, default: "lazy", values: ~w(lazy eager)

  def art(assigns) do
    key = if assigns.cover in @covers, do: assigns.cover, else: "default"
    assigns = assign(assigns, key: key, image: @images[key])

    ~H"""
    <div :if={@image} class={["art", "art-image", "art-#{@key}", @class]}>
      <img
        src={~p"/images/art/#{@key <> ".webp"}"}
        width={elem(@image, 0)}
        height={elem(@image, 1)}
        alt={cover_name(@key)}
        loading={@loading}
        decoding="async"
        class="art-img"
      />
    </div>
    <div
      :if={!@image}
      class={["art", "art-#{@key}", @class]}
      role="img"
      aria-label={gettext("Placeholder illustration: %{theme}", theme: cover_name(@key))}
    >
    </div>
    """
  end

  defp cover_name("forest"), do: gettext("an enchanted forest")
  defp cover_name("observatory"), do: gettext("a starlit observatory")
  defp cover_name("alchemy"), do: gettext("an alchemy workshop")
  defp cover_name("archive"), do: gettext("an ancient archive")
  defp cover_name("hero"), do: gettext("the academy at dusk")
  defp cover_name(_), do: gettext("a magical landscape")

  @doc "Small text chip (never colour-only: always carries a word)."
  attr :kind, :string, default: "neutral", values: ~w(neutral premium free success info danger)
  attr :icon, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def tag(assigns) do
    ~H"""
    <span class={["tag", "tag-#{@kind}"]} {@rest}>
      <.icon :if={@icon} name={@icon} class="size-3.5" />{render_slot(@inner_block)}
    </span>
    """
  end

  attr :premium, :boolean, default: false

  def access_tag(assigns) do
    ~H"""
    <.tag :if={@premium} kind="premium" icon="hero-sparkles">{gettext("Premium")}</.tag>
    <.tag :if={!@premium} kind="free">{gettext("Free")}</.tag>
    """
  end

  @doc "Adventure summary card; the whole card is clickable through a single link."
  attr :adventure, :map, required: true
  attr :id, :string, default: nil

  attr :heading, :string,
    default: "h3",
    values: ~w(h2 h3),
    doc: "level of the title (no level skipped)"

  def adventure_card(assigns) do
    ~H"""
    <article id={@id} class="adventure-card">
      <.art cover={@adventure["cover"]} class="aspect-[16/9]" />
      <div class="flex flex-1 flex-col gap-3 p-5">
        <div class="flex flex-wrap gap-2">
          <.tag>{category_label(@adventure["category"])}</.tag>
          <.tag>{difficulty_label(@adventure["difficulty"])}</.tag>
          <.access_tag premium={@adventure["premium"] == true} />
        </div>
        <.dynamic_tag tag_name={@heading} class="text-2xl">
          <.link navigate={~p"/adventures/#{@adventure["slug"]}"} class="card-link">
            {@adventure["title"]}
          </.link>
        </.dynamic_tag>
        <p class="flex-1 text-sm text-muted">{@adventure["summary"]}</p>
        <p :if={is_integer(@adventure["duration_minutes"])} class="meta">
          <.icon name="hero-clock" class="size-4" />
          {ngettext("%{count} minute", "%{count} minutes", @adventure["duration_minutes"])}
        </p>
      </div>
    </article>
    """
  end

  @doc "Accessible progress bar drawn in SVG (no inline style, CSP-friendly)."
  attr :value, :integer, required: true
  attr :max, :integer, default: 100
  attr :label, :string, required: true
  attr :tone, :string, default: "magic", values: ~w(magic reward success info)
  attr :class, :any, default: nil

  def progress(assigns) do
    max = max(assigns.max, 1)
    value = assigns.value |> max(0) |> min(max)
    fill = %{"magic" => "fill-magic", "reward" => "fill-reward", "success" => "fill-success"}

    assigns =
      assign(assigns,
        max: max,
        value: value,
        pct: Float.round(value * 100 / max, 1),
        fill: Map.get(fill, assigns.tone, "fill-info")
      )

    ~H"""
    <div
      role="progressbar"
      aria-label={@label}
      aria-valuemin="0"
      aria-valuemax={@max}
      aria-valuenow={@value}
      class={@class}
    >
      <svg viewBox="0 0 100 4" preserveAspectRatio="none" class="progress" aria-hidden="true">
        <rect width="100" height="4" class="fill-raised" />
        <rect width={@pct} height="4" class={@fill} />
      </svg>
    </div>
    """
  end

  @doc "Seven-day XP bars (SVG, values as text) + an equivalent table for assistive technologies."
  attr :id, :string, required: true
  attr :week, :list, required: true

  def week_chart(assigns) do
    top = assigns.week |> Enum.map(&(&1["xp"] || 0)) |> Enum.max(fn -> 0 end) |> max(1)
    today = Date.utc_today() |> Date.to_iso8601()

    bars =
      for day <- assigns.week do
        xp = day["xp"] || 0
        label = if day["date"] == today, do: gettext("Today"), else: weekday(day["date"])
        %{date: day["date"], xp: xp, label: label, height: round(xp * 100 / top)}
      end

    assigns = assign(assigns, bars: bars, total: Enum.sum(Enum.map(bars, & &1.xp)))

    ~H"""
    <figure id={@id} class="space-y-3">
      <div class="grid grid-cols-7 items-end gap-2" aria-hidden="true">
        <div :for={bar <- @bars} class="flex flex-col items-center gap-1.5">
          <span class="bar-label tabular-nums text-muted">{bar.xp}</span>
          <svg viewBox="0 0 10 100" preserveAspectRatio="none" class="bar">
            <rect width="10" height="100" class="fill-raised" />
            <rect y={100 - bar.height} width="10" height={bar.height} class="fill-magic" />
          </svg>
          <span class="bar-label text-muted">{bar.label}</span>
        </div>
      </div>
      <figcaption class="text-sm text-muted">
        {gettext("%{total} XP earned over the last 7 days.", total: @total)}
      </figcaption>
      <table class="sr-only">
        <caption>{gettext("XP earned per day")}</caption>
        <thead>
          <tr>
            <th scope="col">{gettext("Day")}</th>
            <th scope="col">{gettext("XP")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={bar <- @bars}>
            <td>{date(bar.date)}</td>
            <td>{bar.xp}</td>
          </tr>
        </tbody>
      </table>
    </figure>
    """
  end

  @crests ~w(moon star flame leaf key book)

  @doc "Preset crests a member can choose as avatar (`priv/static/images/crests/<key>.svg`)."
  def crests, do: @crests

  @doc "Member avatar: uploaded image, preset crest or initials."
  attr :user, :map, required: true
  attr :size, :string, default: "md", values: ~w(sm md lg)

  def avatar(assigns) do
    assigns =
      assign(assigns,
        tone: :erlang.phash2(assigns.user["id"], 4),
        src:
          case assigns.user["avatar"] do
            %{"kind" => "image", "key" => key} when is_binary(key) ->
              ~p"/media/avatars/#{key}"

            %{"kind" => "crest", "key" => key} when key in @crests ->
              ~p"/images/crests/#{key <> ".svg"}"

            _ ->
              nil
          end
      )

    ~H"""
    <img
      :if={@src}
      src={@src}
      alt=""
      class={["avatar", "avatar-#{@size}", "avatar-picture"]}
      loading="lazy"
      decoding="async"
    />
    <span :if={!@src} class={["avatar", "avatar-#{@size}", "avatar-tone-#{@tone}"]} aria-hidden="true">
      {initials(@user["display_name"] || @user["username"])}
    </span>
    """
  end

  @doc "Shown name of a member, translated for an account deleted by accounts."
  def member_name(%{"username" => "deleted_" <> _}), do: gettext("Deleted member")
  def member_name(%{"display_name" => name}) when is_binary(name), do: name
  def member_name(%{"username" => username}) when is_binary(username), do: username
  def member_name(_user), do: nil

  @doc "An account anonymised by its deletion (`deleted_…` username)."
  def deleted_member?(%{"username" => "deleted_" <> _}), do: true
  def deleted_member?(_user), do: false

  @doc "Identity of a member next to a contribution: avatar, display name and `@username`."
  attr :user, :map, default: nil
  attr :size, :string, default: "sm", values: ~w(sm md lg)
  attr :class, :any, default: nil
  slot :inner_block, doc: "extra text after the username (e.g. « you »)"

  def identity(assigns) do
    user = assigns.user || %{}
    username = user["username"]
    member? = is_binary(username) and not deleted_member?(user)

    assigns =
      assign(assigns,
        member: user,
        username: if(member?, do: username),
        name: member_name(user) || gettext("Unknown member")
      )

    ~H"""
    <span class={["identity", @class]}>
      <.avatar user={@member} size={@size} />
      <span class="identity-names">
        <.link :if={@username} navigate={~p"/members/#{@username}"} class="identity-name">
          {@name}
        </.link>
        <span :if={!@username} class="identity-name">{@name}</span>
        <span :if={@username} class="identity-handle">@{@username}</span>
        {render_slot(@inner_block)}
      </span>
    </span>
    """
  end

  @doc "Numeric badge with a text alternative (e.g. unread messages)."
  attr :count, :any, default: nil
  attr :label, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def count_badge(assigns) do
    ~H"""
    <span :if={is_integer(@count) and @count > 0} class={["count-badge", @class]} {@rest}>
      {@count}<span class="sr-only">{@label}</span>
    </span>
    """
  end

  @doc "Membership plan card, with the web application's own advantages listed after billing's features."
  attr :plan, :map, required: true
  attr :current, :boolean, default: false
  attr :id, :string, default: nil
  attr :extra, :list, default: []
  slot :action

  def plan_card(assigns) do
    ~H"""
    <article
      id={@id}
      class={["plan-card", @plan["key"] == "premium" && "plan-card-featured"]}
    >
      <div class="flex items-start justify-between gap-3">
        <h3 class="text-3xl">{plan_title(@plan)}</h3>
        <.tag :if={@current} kind="success" icon="hero-check">{gettext("Current plan")}</.tag>
      </div>
      <p class="flex flex-wrap items-baseline gap-x-2">
        <span class="font-display text-5xl text-ink">
          {money(@plan["price_cents"], @plan["currency"])}
        </span>
        <span class="text-muted">
          {if @plan["interval"] == "month", do: gettext("per month"), else: @plan["interval"]}
        </span>
      </p>
      <ul class="space-y-2 text-sm">
        <li
          :for={feature <- Enum.map(@plan["features"] || [], &plan_feature/1) ++ @extra}
          class="flex gap-2"
        >
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          <span>{feature}</span>
        </li>
      </ul>
      <div :if={@action != []} class="mt-auto pt-2">{render_slot(@action)}</div>
    </article>
    """
  end

  @doc """
  Name of a plan of billing (`GET /api/plans`), in the page's language for the known keys (`free`, `premium`,
  `vip`); any other plan keeps the name given by billing.
  """
  def plan_title(%{"key" => "free"}), do: gettext("Free")
  def plan_title(%{"key" => "premium"}), do: gettext("Premium")
  def plan_title(%{"key" => "vip"}), do: gettext("VIP")
  def plan_title(%{"name" => name}), do: name
  def plan_title(_plan), do: nil

  # Advantages of the plans as configured in billing (config :billing, :plans), translated when known; a text billing
  # adds later is shown as received until it is declared here.
  @plan_features [
    gettext_noop("All free adventures"),
    gettext_noop("XP, levels and streaks"),
    gettext_noop("Friends and messages"),
    gettext_noop("Everything in Free"),
    gettext_noop("All premium adventures"),
    gettext_noop("Everything in Premium"),
    gettext_noop("Supports new adventure development")
  ]

  @doc "An advantage of a plan given by billing, in the page's language when it is a known text."
  def plan_feature(feature) when feature in @plan_features,
    do: Gettext.gettext(MysticWeb.Gettext, feature)

  def plan_feature(feature), do: feature

  @doc "Banner describing the payment mode reported by billing."
  attr :mode, :string, default: nil

  def payment_mode_banner(assigns) do
    ~H"""
    <.notice
      :if={@mode == "local"}
      id="payment-mode"
      kind="reward"
      title={gettext("Demo payment mode — no real money")}
    >
      {gettext(
        "Checkout is simulated on this server: no card is requested and nothing is charged. Your plan still changes only after the (simulated) payment confirmation."
      )}
    </.notice>
    <.notice
      :if={@mode == "disabled"}
      id="payment-mode"
      kind="warning"
      title={gettext("Payments not configured")}
    >
      {gettext("Subscriptions can't be purchased on this server for now.")}
    </.notice>
    <.notice
      :if={@mode == "stripe"}
      id="payment-mode"
      kind="info"
      title={gettext("Secure payments by Stripe")}
    >
      {gettext("You will be redirected to Stripe to pay. Card details never reach MysticLore.")}
    </.notice>
    """
  end
end
