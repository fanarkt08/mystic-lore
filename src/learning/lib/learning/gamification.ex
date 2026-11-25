defmodule MlLearning.Gamification do
  @moduledoc """
  Badges et quêtes quotidiennes, recalculés sur les données réelles après chaque gain d'XP validé.
  """
  alias MlLearning.Progress
  alias MlLearning.Gamification.{Badges, Quests}

  @doc "Règle les quêtes du jour puis les badges ; renvoie les badges gagnés par cet appel."
  def after_xp(user_id, today \\ Date.utc_today()) do
    Quests.settle(user_id, today)
    Badges.award(user_id, today)
  end

  @doc "Quêtes du jour, récompenses dues versées : `[%{quest, progress, completed}]`."
  def settle_quests(user_id, today \\ Date.utc_today()) do
    {quests, rewarded} = Quests.settle(user_id, today)
    if rewarded != [], do: Badges.award(user_id, today)
    quests
  end

  @doc "XP accordée par un autre service (`POST /api/internal/xp`), puis évaluation : `:awarded` ou `:duplicate`."
  def award_xp(user_id, ref_key, amount) do
    with :awarded <- Progress.award_xp(user_id, ref_key, amount) do
      after_xp(user_id)
      :awarded
    end
  end

  @doc "Profil public (sans être l'utilisateur) : niveau, XP, badges gagnés et équipés, aventures terminées."
  def profile(user_id) do
    %{xp: xp, level: level} = Progress.xp_stats(user_id)

    %{
      user_id: user_id,
      level: level,
      xp: xp,
      badges_earned: Badges.earned_count(user_id),
      equipped: Badges.equipped(user_id),
      adventures_completed: Progress.adventures_completed(user_id)
    }
  end

  @doc "Résumé pour le tableau de bord : badges équipés, nombre gagné, taille du catalogue."
  def badge_summary(user_id),
    do: %{
      equipped: Badges.equipped(user_id),
      earned: Badges.earned_count(user_id),
      total: Badges.total()
    }
end
