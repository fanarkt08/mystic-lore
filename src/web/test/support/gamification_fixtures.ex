defmodule MysticWeb.GamificationFixtures do
  @moduledoc "Fictional learning payloads for badges and quests."

  @public ~w(id slug name description icon rarity position)

  def achievement(attrs) do
    Map.merge(
      %{
        "id" => "b-#{attrs["slug"]}",
        "description" => "A badge of the academy.",
        "icon" => "hero-sun",
        "rarity" => "common",
        "criterion" => "lessons_completed",
        "earned" => true,
        "earned_at" => "2026-11-21T10:00:00Z",
        "equipped" => false,
        "position" => nil,
        "progress" => %{"current" => 1, "target" => 1}
      },
      attrs
    )
  end

  @doc "Léa-like catalogue: two earned badges (the first equipped), two locked ones."
  def catalogue do
    [
      achievement(%{
        "slug" => "sprout-tender",
        "name" => "Main verte",
        "rarity" => "uncommon",
        "criterion" => "lesson_completed",
        "equipped" => true,
        "position" => 1
      }),
      achievement(%{"slug" => "trailblazer", "name" => "Bout du chemin", "icon" => "hero-flag"}),
      achievement(%{
        "slug" => "five-hundred-runes",
        "name" => "Cinq cents runes",
        "icon" => "hero-bolt",
        "rarity" => "rare",
        "criterion" => "total_xp",
        "earned" => false,
        "earned_at" => nil,
        "progress" => %{"current" => 155, "target" => 500}
      }),
      achievement(%{
        "slug" => "moonlit-week",
        "name" => "Semaine au clair de lune",
        "icon" => "hero-moon",
        "criterion" => "streak_days",
        "earned" => false,
        "earned_at" => nil,
        "progress" => %{"current" => 5, "target" => 7}
      })
    ]
  end

  @doc "`GET /api/me/achievements` body; `equipped` follows the badges' positions."
  def achievements(badges) do
    equipped =
      badges
      |> Enum.filter(& &1["equipped"])
      |> Enum.sort_by(& &1["position"])
      |> Enum.map(&Map.take(&1, @public))

    %{"badges" => badges, "equipped" => equipped, "max_equipped" => 3}
  end

  @doc "What learning answers to `PUT /api/me/badges/equipped` with these ids (assumed valid)."
  def equip(badges, ids) do
    badges
    |> Enum.map(fn badge ->
      position = Enum.find_index(ids, &(&1 == badge["id"]))
      %{badge | "equipped" => position != nil, "position" => position && position + 1}
    end)
    |> achievements()
  end

  def equipped_badge(attrs),
    do:
      Map.merge(
        %{
          "id" => "b-#{attrs["slug"]}",
          "description" => "A badge of the academy.",
          "icon" => "hero-sun",
          "rarity" => "uncommon",
          "position" => 1
        },
        attrs
      )

  def quests do
    [
      %{
        "id" => "q1",
        "slug" => "daily-lesson",
        "title" => "Complete a lesson",
        "description" => "Finish any lesson today.",
        "kind" => "lessons_completed",
        "target" => 1,
        "progress" => 1,
        "completed" => true,
        "xp_reward" => 15
      },
      %{
        "id" => "q2",
        "slug" => "daily-xp",
        "title" => "Earn 30 XP",
        "description" => "Earn 30 XP today. Quest rewards don't count.",
        "kind" => "xp_earned",
        "target" => 30,
        "progress" => 10,
        "completed" => false,
        "xp_reward" => 20
      }
    ]
  end

  @doc "`GET /api/me/dashboard` body with the gamification fields."
  def dashboard(attrs \\ %{}) do
    today = Date.utc_today()

    Map.merge(
      %{
        "level" => 2,
        "xp" => 170,
        "into_level" => 20,
        "per_level" => 150,
        "streak" => 5,
        "week" =>
          for(i <- 6..0//-1, do: %{"date" => Date.to_iso8601(Date.add(today, -i)), "xp" => 10}),
        "current" => nil,
        "recommendations" => [],
        "quests" => quests(),
        "equipped_badges" => [
          equipped_badge(%{"slug" => "sprout-tender", "name" => "Main verte"}),
          equipped_badge(%{
            "slug" => "trailblazer",
            "name" => "Bout du chemin",
            "rarity" => "rare",
            "position" => 2
          })
        ],
        "badges_earned" => 5,
        "badges_total" => 10
      },
      attrs
    )
  end
end
