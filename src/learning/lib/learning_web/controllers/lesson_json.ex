defmodule MlLearningWeb.LessonJSON do
  # Seul `content` est exposé : `solution` (réponse attendue, critère d'une simulation, ordre d'un
  # mini-jeu) n'est jamais sérialisée.
  alias MlLearning.{Minigame, Offline}

  def show(%{lesson: lesson, user_id: user_id, progress: progress} = assigns) do
    %{
      lesson:
        lesson
        |> Map.take([:id, :title, :kind, :body, :xp_reward])
        |> Map.put(:content, Minigame.public(lesson, user_id)),
      adventure: Map.take(lesson.chapter.adventure, [:slug, :title]),
      progress: Map.take(progress, [:status, :attempts, :notes, :draft]),
      prev_id: assigns.prev_id,
      next_id: assigns.next_id,
      offline: Offline.summary(lesson)
    }
  end
end
