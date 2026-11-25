defmodule MlLearningWeb.AdventureJSON do
  alias MlLearning.Catalog.Adventure

  @card [
    :id,
    :slug,
    :title,
    :summary,
    :category,
    :difficulty,
    :premium,
    :duration_minutes,
    :cover
  ]

  def index(%{page: page}), do: %{page | entries: Enum.map(page.entries, &card/1)}

  def show(%{adventure: %Adventure{} = adventure, access: access, state: state}) do
    adventure
    |> card()
    |> Map.merge(%{
      description: adventure.description,
      objectives: adventure.objectives,
      prerequisites: adventure.prerequisites,
      chapters: Enum.map(adventure.chapters, &chapter(&1, state.completed)),
      access: access,
      enrolled: state.enrolled,
      progress: state.progress,
      resume_lesson_id: state.resume_lesson_id
    })
  end

  @doc "Forme « aventure (liste) » du contrat."
  def card(%Adventure{} = adventure), do: Map.take(adventure, @card)

  defp chapter(chapter, completed) do
    %{
      id: chapter.id,
      position: chapter.position,
      title: chapter.title,
      lessons:
        Enum.map(chapter.lessons, fn lesson ->
          lesson
          |> Map.take([:id, :position, :title, :kind, :xp_reward])
          |> Map.put(:completed, MapSet.member?(completed, lesson.id))
        end)
    }
  end
end
