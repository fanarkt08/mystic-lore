defmodule MlLearningWeb.GamificationController do
  use MlLearningWeb, :controller
  alias MlLearning.Gamification
  alias MlLearning.Gamification.Badges

  action_fallback MlLearningWeb.FallbackController

  def achievements(conn, _params),
    do: render(conn, :achievements, achievements: Badges.achievements(conn.assigns.user_id))

  @doc "Remplacement atomique des badges équipés ; répond avec l'état complet, comme `achievements/2`."
  def equip(conn, params) do
    with {:ok, _ids} <- Badges.equip(conn.assigns.user_id, params["badge_ids"]),
         do: achievements(conn, params)
  end

  def quests(conn, _params) do
    today = Date.utc_today()

    render(conn, :quests,
      date: today,
      quests: Gamification.settle_quests(conn.assigns.user_id, today)
    )
  end

  def profile(conn, %{"id" => id}) do
    with {:ok, user_id} <- MlLearning.cast_uuid(id) do
      render(conn, :profile, profile: Gamification.profile(user_id))
    else
      :error -> {:error, :not_found}
    end
  end
end
