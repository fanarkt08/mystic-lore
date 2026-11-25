defmodule MlLearningWeb.DashboardController do
  use MlLearningWeb, :controller
  alias MlLearning.{Gamification, Progress}

  @categories ~w(coding science humanities creative)

  @doc "`?categories=science,creative` : ordre des recommandations (catégories inconnues ignorées)."
  def show(conn, params) do
    user_id = conn.assigns.user_id

    # quêtes réglées avant le calcul : XP et niveau incluent une récompense versée à cette lecture
    quests = Gamification.settle_quests(user_id)

    render(conn, :show,
      dashboard: Progress.dashboard(user_id, Date.utc_today(), categories(params["categories"])),
      quests: quests,
      badges: Gamification.badge_summary(user_id)
    )
  end

  defp categories(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.filter(&(&1 in @categories)) |> Enum.uniq()

  defp categories(_value), do: []
end
