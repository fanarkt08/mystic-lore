defmodule MysticWeb.ProfileComponents do
  @moduledoc """
  Profile labels and the profile card shared by `/members/:username` and the settings preview.
  Both render exactly what accounts returned for the reader.
  """
  use MysticWeb, :html
  import MysticWeb.GamificationComponents, only: [equipped_badges: 1]

  @interests [
    {"astronomy", "science"},
    {"alchemy", "science"},
    {"botany", "science"},
    {"mathematics", "science"},
    {"coding", "coding"},
    {"logic", "coding"},
    {"history", "humanities"},
    {"languages", "humanities"},
    {"mythology", "humanities"},
    {"writing", "creative"},
    {"art", "creative"},
    {"music", "creative"}
  ]

  def interests, do: Enum.map(@interests, &elem(&1, 0))

  @doc "Learning categories of the member's interests, the most represented first (ties: order of choice)."
  def interest_categories(interests) when is_list(interests) do
    map = Map.new(@interests)
    categories = interests |> Enum.map(&map[&1]) |> Enum.reject(&is_nil/1)
    categories |> Enum.uniq() |> Enum.sort_by(fn c -> -Enum.count(categories, &(&1 == c)) end)
  end

  def interest_categories(_interests), do: []

  def interest_label("astronomy"), do: gettext("Astronomy")
  def interest_label("alchemy"), do: gettext("Alchemy & chemistry")
  def interest_label("botany"), do: gettext("Botany & nature")
  def interest_label("mathematics"), do: gettext("Mathematics")
  def interest_label("coding"), do: gettext("Coding")
  def interest_label("logic"), do: gettext("Logic & puzzles")
  def interest_label("history"), do: gettext("History")
  def interest_label("languages"), do: gettext("Languages")
  def interest_label("mythology"), do: gettext("Myths & legends")
  def interest_label("writing"), do: gettext("Writing & storytelling")
  def interest_label("art"), do: gettext("Art & design")
  def interest_label("music"), do: gettext("Music")
  def interest_label(other), do: to_string(other)

  def covers, do: ~w(forest observatory alchemy archive)

  def cover_label("forest"), do: gettext("Enchanted forest")
  def cover_label("observatory"), do: gettext("Starlit observatory")
  def cover_label("alchemy"), do: gettext("Alchemy workshop")
  def cover_label("archive"), do: gettext("Ancient archive")
  def cover_label(_), do: gettext("Academy at dusk (default)")

  def crest_label("moon"), do: gettext("Crescent moon")
  def crest_label("star"), do: gettext("Guiding star")
  def crest_label("flame"), do: gettext("Ember flame")
  def crest_label("leaf"), do: gettext("Grove leaf")
  def crest_label("key"), do: gettext("Archivist's key")
  def crest_label("book"), do: gettext("Open grimoire")
  def crest_label(other), do: to_string(other)

  def visibilities, do: ~w(public members friends private)

  def visibility_label("public"), do: gettext("Everyone")
  def visibility_label("members"), do: gettext("Members")
  def visibility_label("friends"), do: gettext("Friends")
  def visibility_label("private"), do: gettext("Only me")
  def visibility_label(other), do: to_string(other)

  def visibility_hint("public"), do: gettext("Visitors who are not signed in see it too.")
  def visibility_hint("members"), do: gettext("Signed-in members only.")
  def visibility_hint("friends"), do: gettext("Only your friends.")
  def visibility_hint("private"), do: gettext("Nobody but you.")
  def visibility_hint(_), do: ""

  @doc "Why a reader can't see the rest of a profile."
  def hidden_notice(name, "members"),
    do:
      gettext("%{name} shares the rest of their profile with signed-in members only.", name: name)

  def hidden_notice(name, "friends"),
    do: gettext("%{name} shares the rest of their profile with their friends only.", name: name)

  def hidden_notice(name, _visibility),
    do: gettext("%{name} keeps the rest of their profile private.", name: name)

  # the level under the card's name (h1 → h2…): no level is skipped
  defp sub_heading("h1"), do: "h2"
  defp sub_heading("h2"), do: "h3"
  defp sub_heading(_heading), do: "h4"

  @doc "Profile card: cover, identity, pronouns, bio and interests (as filtered by accounts)."
  attr :id, :string, required: true
  attr :name_id, :string, required: true, doc: "id of the heading holding the display name"
  attr :profile, :map, required: true
  attr :heading, :string, default: "h1", values: ~w(h1 h2 h3)
  slot :badges, doc: "relation tags (friend, blocked)"
  slot :inner_block, doc: "actions"

  def profile_card(assigns) do
    assigns = assign(assigns, details: assigns.profile["details"])

    ~H"""
    <section id={@id} class="card profile-card" aria-labelledby={@name_id}>
      <.art cover={@profile["cover"]} class="profile-cover" label={false} />
      <div class="profile-head">
        <.avatar user={@profile} size="lg" />
        <div class="profile-names min-w-0 flex-1 space-y-1">
          <.dynamic_tag
            tag_name={@heading}
            id={@name_id}
            class="break-words text-4xl md:text-5xl"
          >
            {@profile["display_name"]}
          </.dynamic_tag>
          <p class="text-muted">
            @{@profile["username"]}
            <span :if={@details && @details["pronouns"]} id={"#{@id}-pronouns"}>
              · {@details["pronouns"]}
            </span>
          </p>
        </div>
        {render_slot(@badges)}
      </div>
      <%= if @details do %>
        <p :if={@details["bio"] not in [nil, ""]} id={"#{@id}-bio"} class="whitespace-pre-line">
          {@details["bio"]}
        </p>
        <p :if={@details["bio"] in [nil, ""]} class="text-muted">
          {gettext("This member hasn't written a bio yet.")}
        </p>
        <div :if={(@details["interests"] || []) != []} class="space-y-2">
          <.dynamic_tag
            tag_name={sub_heading(@heading)}
            class="font-sans text-sm font-semibold text-muted"
          >
            {gettext("Interests")}
          </.dynamic_tag>
          <ul id={"#{@id}-interests"} class="flex flex-wrap gap-2">
            <li :for={interest <- @details["interests"]}>
              <.tag kind="info">{interest_label(interest)}</.tag>
            </li>
          </ul>
        </div>
      <% else %>
        <.notice id={"#{@id}-hidden"} kind="info">
          {hidden_notice(@profile["display_name"], @profile["visibility"])}
        </.notice>
      <% end %>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "Academy record from learning (level, XP, badges): shown only when accounts shared the profile."
  attr :id, :string, required: true
  attr :equipped_id, :string, required: true
  attr :record, :any, required: true
  attr :self, :boolean, default: false

  def record_card(assigns) do
    ~H"""
    <section id={@id} class="card space-y-5" aria-labelledby={"#{@id}-title"}>
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h2 id={"#{@id}-title"} class="text-2xl">{gettext("Academy record")}</h2>
        <.link :if={@self} navigate={~p"/achievements"} class="link text-sm" id="manage-badges">
          {gettext("Manage my badges")} →
        </.link>
      </div>
      <%= if @record == :unavailable do %>
        <.unavailable>{gettext("This member's progress can't be loaded right now.")}</.unavailable>
      <% else %>
        <dl class="grid grid-cols-2 gap-4 sm:grid-cols-4">
          <div :for={
            {label, value} <- [
              {gettext("Level"), @record["level"]},
              {gettext("XP"), @record["xp"]},
              {gettext("Badges earned"), @record["badges_earned"]},
              {gettext("Adventures completed"), @record["adventures_completed"]}
            ]
          }>
            <dt class="text-sm text-muted">{label}</dt>
            <dd class="font-display text-3xl text-ink tabular-nums">{value}</dd>
          </div>
        </dl>
        <div class="space-y-3">
          <h3 class="text-xl">{gettext("Equipped badges")}</h3>
          <.equipped_badges
            :if={(@record["equipped_badges"] || []) != []}
            id={@equipped_id}
            badges={@record["equipped_badges"]}
          />
          <p :if={(@record["equipped_badges"] || []) == []} class="text-sm text-muted">
            {gettext("No badge equipped.")}
          </p>
        </div>
      <% end %>
    </section>
    """
  end
end
