defmodule MysticWeb.GamificationComponents do
  @moduledoc """
  Badges and daily quests, from learning (`GET /api/me/achievements`, `/api/me/dashboard`, `/api/users/:id/profile`).
  Statuses are always written in words: icons and colours only repeat them.
  """
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  import MysticWeb.CoreComponents, only: [button: 1, icon: 1]
  import MysticWeb.MysticComponents, only: [progress: 1, tag: 1]
  import MysticWeb.Format, only: [date: 1]

  # Same whitelist as learning (database constraint), written out so that Tailwind generates these `hero-*` classes.
  @icons ~w(hero-sparkles hero-sun hero-flag hero-star hero-bolt hero-academic-cap hero-trophy hero-fire
            hero-moon hero-users hero-book-open hero-shield-check hero-light-bulb hero-puzzle-piece hero-map
            hero-beaker hero-rocket-launch hero-pencil-square)

  @doc "A whitelisted badge icon (anything else falls back to sparkles)."
  def badge_icon(icon) when icon in @icons, do: icon
  def badge_icon(_icon), do: "hero-sparkles"

  def rarity_label("uncommon"), do: gettext("Uncommon")
  def rarity_label("rare"), do: gettext("Rare")
  def rarity_label("epic"), do: gettext("Epic")
  def rarity_label("legendary"), do: gettext("Legendary")
  def rarity_label(_rarity), do: gettext("Common")

  @doc "Decorative medallion of a badge (its name is always written next to it)."
  attr :badge, :map, required: true
  attr :locked, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(sm md lg)

  def badge_medal(assigns) do
    ~H"""
    <span
      class={[
        "badge-medal",
        "badge-medal-#{@size}",
        "badge-rarity-#{rarity(@badge["rarity"])}",
        @locked && "badge-medal-locked"
      ]}
      aria-hidden="true"
    >
      <.icon name={badge_icon(@badge["icon"])} class={icon_size(@size)} />
    </span>
    """
  end

  defp rarity(rarity) when rarity in ~w(uncommon rare epic legendary), do: rarity
  defp rarity(_rarity), do: "common"

  defp icon_size("sm"), do: "size-4"
  defp icon_size("lg"), do: "size-8"
  defp icon_size(_size), do: "size-6"

  @doc "Rarity chip, in words."
  attr :rarity, :string, default: nil

  def rarity_tag(assigns) do
    ~H"""
    <span class={["tag", "tag-rarity-#{rarity(@rarity)}"]}>{rarity_label(@rarity)}</span>
    """
  end

  @doc "Equipped badges in their order (dashboard, member profiles)."
  attr :id, :string, required: true
  attr :badges, :list, required: true

  def equipped_badges(assigns) do
    ~H"""
    <ol id={@id} class="equipped-list">
      <li :for={badge <- @badges} class="equipped-item">
        <.badge_medal badge={badge} size="sm" />
        <span class="min-w-0">
          <span class="block truncate font-medium text-ink">{badge["name"]}</span>
          <span class="block text-xs text-muted">{rarity_label(badge["rarity"])}</span>
        </span>
      </li>
    </ol>
    """
  end

  @doc "One badge of the catalogue for the member: status, progress or earned date, equip button."
  attr :badge, :map, required: true

  def achievement_card(assigns) do
    ~H"""
    <li
      id={"badge-#{@badge["slug"]}"}
      class={["achievement", @badge["earned"] && "achievement-earned"]}
    >
      <div class="flex items-start gap-4">
        <.badge_medal badge={@badge} locked={!@badge["earned"]} size="lg" />
        <div class="min-w-0 flex-1 space-y-2">
          <h3 class="text-2xl break-words">{@badge["name"]}</h3>
          <p class="flex flex-wrap gap-2">
            <.tag :if={@badge["earned"]} kind="success" icon="hero-check-circle">
              {gettext("Earned")}
            </.tag>
            <.tag :if={!@badge["earned"]} icon="hero-lock-closed">{gettext("Locked")}</.tag>
            <.tag :if={@badge["equipped"]} kind="info" icon="hero-star">
              {gettext("Equipped in slot %{position}", position: @badge["position"])}
            </.tag>
            <.rarity_tag rarity={@badge["rarity"]} />
          </p>
        </div>
      </div>
      <p class="text-sm text-muted">{@badge["description"]}</p>
      <%= if @badge["earned"] do %>
        <p class="text-sm">{gettext("Earned on %{date}", date: date(@badge["earned_at"]))}</p>
      <% else %>
        <div class="space-y-2">
          <.progress
            value={get_in(@badge, ["progress", "current"]) || 0}
            max={get_in(@badge, ["progress", "target"]) || 1}
            label={gettext("Progress towards %{name}", name: @badge["name"])}
          />
          <p class="text-sm tabular-nums text-muted">{criterion_progress(@badge)}</p>
        </div>
      <% end %>
      <div :if={@badge["earned"]} class="mt-auto">
        <.button
          :if={!@badge["equipped"]}
          id={"equip-#{@badge["slug"]}"}
          phx-click="equip"
          phx-value-id={@badge["id"]}
          variant="secondary"
        >
          <.icon name="hero-plus-circle" /> {gettext("Equip")}
          <span class="sr-only">{@badge["name"]}</span>
        </.button>
        <.button
          :if={@badge["equipped"]}
          id={"unequip-#{@badge["slug"]}"}
          phx-click="unequip"
          phx-value-id={@badge["id"]}
          variant="ghost"
        >
          <.icon name="hero-minus-circle" /> {gettext("Unequip")}
          <span class="sr-only">{@badge["name"]}</span>
        </.button>
      </div>
    </li>
    """
  end

  @doc "Progress towards a badge criterion, in words (`criterion` and `progress` from learning)."
  def criterion_progress(%{"criterion" => criterion, "progress" => %{} = progress}) do
    current = progress["current"] || 0
    target = progress["target"] || 1

    case criterion do
      "lesson_completed" when current >= target ->
        gettext("Lesson completed")

      "lesson_completed" ->
        gettext("Lesson not completed yet")

      "lessons_completed" ->
        ngettext(
          "%{current} of %{count} lesson completed",
          "%{current} of %{count} lessons completed",
          target,
          current: current
        )

      "adventures_completed" ->
        ngettext(
          "%{current} of %{count} adventure finished",
          "%{current} of %{count} adventures finished",
          target,
          current: current
        )

      "total_xp" ->
        gettext("%{current} of %{target} XP", current: current, target: target)

      "level" ->
        gettext("Level %{current} of %{target}", current: current, target: target)

      "streak_days" ->
        ngettext(
          "%{current} of %{count} day in a row",
          "%{current} of %{count} days in a row",
          target,
          current: current
        )

      "multiplayer_wins" ->
        ngettext(
          "%{current} of %{count} multiplayer victory",
          "%{current} of %{count} multiplayer victories",
          target,
          current: current
        )

      _ ->
        "#{current} / #{target}"
    end
  end

  def criterion_progress(_badge), do: ""

  @doc "Today's quests with their progress (`completed` means the XP reward was granted)."
  attr :quests, :list, required: true

  def quest_list(assigns) do
    ~H"""
    <ul class="space-y-5">
      <li :for={quest <- @quests} id={"quest-#{quest["slug"]}"} class="quest">
        <span class={["quest-icon", quest["completed"] && "quest-icon-done"]} aria-hidden="true">
          <.icon name={if quest["completed"], do: "hero-check", else: quest_icon(quest["kind"])} />
        </span>
        <div class="min-w-0 flex-1 space-y-2">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <p class="font-medium text-ink">{quest["title"]}</p>
            <.tag :if={quest["completed"]} kind="success" icon="hero-check-circle">
              {gettext("Completed · +%{xp} XP earned", xp: quest["xp_reward"])}
            </.tag>
            <.tag :if={!quest["completed"]}>
              {gettext("Reward: %{xp} XP", xp: quest["xp_reward"])}
            </.tag>
          </div>
          <p class="text-sm text-muted">{quest["description"]}</p>
          <.progress
            value={quest["progress"] || 0}
            max={quest["target"] || 1}
            tone={if quest["completed"], do: "success", else: "magic"}
            label={gettext("Progress of the quest %{title}", title: quest["title"])}
          />
          <p class="text-xs tabular-nums text-muted">{quest_progress(quest)}</p>
        </div>
      </li>
    </ul>
    """
  end

  defp quest_icon("lessons_completed"), do: "hero-book-open"
  defp quest_icon("xp_earned"), do: "hero-bolt"
  defp quest_icon("note_written"), do: "hero-pencil-square"
  defp quest_icon(_kind), do: "hero-sparkles"

  defp quest_progress(quest) do
    progress = quest["progress"] || 0
    target = quest["target"] || 1

    case quest["kind"] do
      "lessons_completed" ->
        ngettext("%{progress} of %{count} lesson", "%{progress} of %{count} lessons", target,
          progress: progress
        )

      "note_written" ->
        ngettext("%{progress} of %{count} note", "%{progress} of %{count} notes", target,
          progress: progress
        )

      "xp_earned" ->
        gettext("%{progress} of %{target} XP", progress: progress, target: target)

      _ ->
        "#{progress} / #{target}"
    end
  end
end
