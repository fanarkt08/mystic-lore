defmodule MlLearningWeb.DashboardJSON do
  alias MlLearningWeb.{AdventureJSON, GamificationJSON}

  # Forme du contrat + champs additionnels de gamification (quêtes du jour, badges équipés, compteurs).
  def show(%{dashboard: dashboard, quests: quests, badges: badges}) do
    dashboard
    |> Map.put(:recommendations, Enum.map(dashboard.recommendations, &AdventureJSON.card/1))
    |> Map.merge(%{
      quests: Enum.map(quests, &GamificationJSON.quest/1),
      equipped_badges: GamificationJSON.equipped(badges.equipped),
      badges_earned: badges.earned,
      badges_total: badges.total
    })
  end
end
