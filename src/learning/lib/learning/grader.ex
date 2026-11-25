defmodule MlLearning.Grader do
  @moduledoc """
  Corrige les réponses côté serveur selon le format de la leçon.
  La solution n'est jamais exposée : une erreur renvoie l'indice, pas la réponse.
  """
  alias MlLearning.{Minigame, Sim}
  alias MlLearning.Catalog.Lesson

  def grade(lesson, answer, user_id \\ nil)

  def grade(%Lesson{kind: "coding", content: content}, answer, _user_id),
    do: {:ok, MlLearning.GroveScript.grade(answer, (content || %{})["plants"] || 3)}

  def grade(%Lesson{kind: "exercise", content: content, solution: solution}, answer, _user_id) do
    expected = solution["answer"]

    correct =
      is_binary(expected) and chosen(content["choices"] || [], String.trim(answer)) == expected

    feedback =
      if correct,
        do: solution["explanation"] || "Correct!",
        else: solution["hint"] || "Not quite. Try again."

    {:ok, %{correct: correct, feedback: feedback, trace: nil}}
  end

  def grade(%Lesson{kind: "simulation", content: content, solution: solution}, answer, _user_id) do
    with {:ok, values} <- decode_params(answer),
         {:ok, _response, result} <- Sim.simulate(content, values) do
      {:ok, Map.put(Sim.evaluate(content, solution, result), :trace, nil)}
    end
  end

  def grade(%Lesson{kind: "minigame"} = lesson, answer, user_id),
    do: Minigame.grade(lesson, user_id, answer)

  defp decode_params(answer) do
    case Jason.decode(answer) do
      {:ok, %{} = values} -> {:ok, values}
      _ -> {:error, {:invalid, %{answer: ["must be a JSON object of the simulation parameters"]}}}
    end
  end

  defp chosen(choices, answer) do
    cond do
      answer in choices -> answer
      answer =~ ~r/^\d{1,2}$/ -> Enum.at(choices, String.to_integer(answer))
      true -> nil
    end
  end
end
