defmodule MlLearningWeb.GamificationJSON do
  alias MlLearning.Gamification.{Badge, Badges}

  def achievements(%{achievements: %{badges: entries, equipped: equipped}}) do
    %{
      badges: Enum.map(entries, &achievement/1),
      equipped: Enum.map(equipped, &badge(&1.badge, &1.user_badge.position)),
      max_equipped: Badges.max_equipped()
    }
  end

  def quests(%{date: date, quests: quests}) do
    %{
      date: date,
      resets_at: DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC"),
      quests: Enum.map(quests, &quest/1)
    }
  end

  def profile(%{profile: profile}) do
    profile
    |> Map.delete(:equipped)
    |> Map.put(:equipped_badges, equipped(profile.equipped))
  end

  @doc "Forme publique d'un badge."
  def badge(%Badge{} = badge),
    do: Map.take(badge, [:id, :slug, :name, :description, :icon, :rarity])

  def badge(%Badge{} = badge, position), do: Map.put(badge(badge), :position, position)

  @doc "`[{badge, position}]` → badges publics avec leur position."
  def equipped(list), do: for({badge, position} <- list, do: badge(badge, position))

  def quest(%{quest: quest, progress: progress, completed: completed}) do
    quest
    |> Map.take([:id, :slug, :title, :description, :kind, :target, :xp_reward])
    |> Map.merge(%{progress: progress, completed: completed})
  end

  defp achievement(%{badge: badge, user_badge: user_badge, current: current}) do
    badge
    |> badge()
    |> Map.merge(%{
      criterion: badge.criterion,
      earned: user_badge != nil,
      earned_at: user_badge && user_badge.earned_at,
      equipped: user_badge != nil and user_badge.equipped,
      position: user_badge && user_badge.position,
      progress: %{current: current, target: badge.target}
    })
  end
end
