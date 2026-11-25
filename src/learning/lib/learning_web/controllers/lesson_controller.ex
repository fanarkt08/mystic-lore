defmodule MlLearningWeb.LessonController do
  use MlLearningWeb, :controller
  alias MlLearning.{Catalog, Entitlements, Grader, Offline, Progress, Sim, Video}

  action_fallback MlLearningWeb.FallbackController

  # formats terminés par une réponse corrigée / par « complete »
  @answered ~w(exercise coding simulation minigame)
  @completed ~w(story video)

  def show(conn, %{"id" => id}) do
    with {:ok, lesson} <- accessible_lesson(conn, id),
         {:ok, progress} <- Progress.open(conn.assigns.user_id, lesson) do
      {prev_id, next_id} = Catalog.neighbours(lesson)

      render(conn, :show,
        lesson: lesson,
        user_id: conn.assigns.user_id,
        progress: progress,
        prev_id: prev_id,
        next_id: next_id
      )
    end
  end

  @doc "Renvoie le paquet hors ligne d'une leçon, sans inscription ni autre effet de bord."
  def offline(conn, %{"id" => id}) do
    with {:ok, lesson} <- Catalog.fetch_lesson(id),
         {:ok, package} <- Offline.package(conn.assigns.user_id, lesson) do
      json(conn, %{package: package})
    end
  end

  # Avec `idempotency_key` (action rejouée depuis la file hors ligne), la réponse est rendue une seule fois puis
  # rejouée telle quelle (`replayed`), et `revision` doit être celle de la leçon (409 sinon).
  def submit(conn, %{"id" => id} = params) do
    with {:ok, lesson} <- accessible_lesson(conn, id),
         :ok <-
           if(lesson.kind in @answered,
             do: :ok,
             else: invalid(:lesson, "has no answer to submit")
           ),
         {:ok, answer} <- answer(params["answer"]),
         {:ok, replay} <- Offline.replay_params(params) do
      if replay,
        do: replayed(conn, Offline.submit(conn.assigns.user_id, lesson, answer, replay)),
        else: submit_now(conn, lesson, answer)
    end
  end

  defp submit_now(conn, lesson, answer) do
    with {:ok, result} <- Grader.grade(lesson, answer, conn.assigns.user_id),
         {:ok, xp} <- Progress.submit(conn.assigns.user_id, lesson, result.correct) do
      json(conn, Map.put(result, :xp, xp))
    end
  end

  def complete(conn, %{"id" => id} = params) do
    with {:ok, lesson} <- accessible_lesson(conn, id),
         :ok <-
           if(lesson.kind in @completed, do: :ok, else: invalid(:lesson, "requires an answer")),
         {:ok, replay} <- Offline.replay_params(params) do
      if replay,
        do: replayed(conn, Offline.complete(conn.assigns.user_id, lesson, params, replay)),
        else: complete_now(conn, lesson, params)
    end
  end

  defp complete_now(conn, lesson, params) do
    with :ok <- if(lesson.kind == "video", do: Video.completion(params), else: :ok),
         {:ok, xp} <- Progress.complete(conn.assigns.user_id, lesson) do
      json(conn, %{xp: xp})
    end
  end

  defp replayed(conn, {:ok, response, replayed?}),
    do: json(conn, Map.put(response, "replayed", replayed?))

  defp replayed(_conn, error), do: error

  @doc "Simulation déterministe et bornée, sans effet de bord (ni inscription, ni tentative)."
  def simulate(conn, %{"id" => id} = params) do
    with {:ok, lesson} <- accessible_lesson(conn, id),
         :ok <-
           if(lesson.kind == "simulation", do: :ok, else: invalid(:lesson, "is not a simulation")),
         {:ok, response, _result} <- Sim.simulate(lesson.content, params["params"] || %{}) do
      json(conn, response)
    end
  end

  def notes(conn, params), do: save_text(conn, params, :notes, 4000)
  def draft(conn, params), do: save_text(conn, params, :draft, 2000)

  defp save_text(conn, %{"id" => id} = params, field, max) do
    with {:ok, lesson} <- accessible_lesson(conn, id),
         {:ok, text} <- text(params[Atom.to_string(field)], field, max) do
      :ok = Progress.save_text(conn.assigns.user_id, lesson, field, text)
      send_resp(conn, 204, "")
    end
  end

  defp accessible_lesson(conn, id) do
    with {:ok, lesson} <- Catalog.fetch_lesson(id),
         :ok <- Entitlements.check(lesson.chapter.adventure, conn.assigns.user_id),
         do: {:ok, lesson}
  end

  defp answer(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> invalid(:answer, "can't be blank")
      byte_size(value) > 20_000 -> invalid(:answer, "is too long")
      true -> {:ok, value}
    end
  end

  defp answer(_), do: invalid(:answer, "can't be blank")

  defp text(value, field, max) when is_binary(value) do
    if String.length(value) <= max,
      do: {:ok, value},
      else: invalid(field, "should be at most #{max} character(s)")
  end

  defp text(_value, field, _max), do: invalid(field, "must be a string")

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
