defmodule MlLearning.Offline do
  @moduledoc """
  Paquets des leçons hors ligne et rejeu idempotent des actions faites hors ligne.
  Un paquet ne contient jamais la solution et expire au plus tard à la fin de la période payée.
  """
  import Ecto.Query
  alias MlLearning.{Entitlements, Grader, Progress, Repo, Video}
  alias MlLearning.Catalog.Lesson
  alias MlLearning.Offline.Action

  @max_days 14
  @kinds ~w(story exercise)

  @doc "Durée de vie maximale d'un paquet (jours) ; la fin de la période payée peut la raccourcir."
  def max_days, do: @max_days

  @doc "Leçon proposée hors ligne : `story` ou `exercise` d'une aventure premium."
  def available?(%Lesson{kind: kind, chapter: %{adventure: %{premium: premium}}}),
    do: premium == true and kind in @kinds

  @doc "Résumé exposé avec la leçon (`GET /api/lessons/:id`)."
  def summary(%Lesson{} = lesson),
    do: %{available: available?(lesson), revision: lesson.revision, max_days: @max_days}

  @doc """
  Paquet hors ligne de `lesson` pour `user_id` : `{:ok, map}`, ou `{:error, raison}` parmi
  `:offline_unavailable`, `:premium_required`, `:entitlements_unavailable` et `:no_paid_period`.
  """
  def package(user_id, %Lesson{} = lesson, now \\ DateTime.utc_now(:second)) do
    with :ok <- if(available?(lesson), do: :ok, else: {:error, :offline_unavailable}),
         {:ok, %{premium: true, period_end: period_end}} <- entitlements(user_id),
         {:ok, expires_at, by} <- expiry(now, period_end) do
      adventure = lesson.chapter.adventure

      {:ok,
       %{
         lesson:
           lesson
           |> Map.take([:id, :title, :kind, :body, :content, :xp_reward, :revision, :revised_at]),
         adventure: Map.take(adventure, [:slug, :title]),
         member_id: user_id,
         downloaded_at: now,
         expires_at: expires_at,
         expires_by: by,
         max_days: @max_days
       }}
    end
  end

  defp entitlements(user_id) do
    case Entitlements.fresh(user_id) do
      {:ok, %{premium: true}} = ok -> ok
      {:ok, %{premium: false}} -> {:error, :premium_required}
      {:error, :unavailable} -> {:error, :entitlements_unavailable}
    end
  end

  defp expiry(_now, nil), do: {:error, :no_paid_period}

  defp expiry(now, period_end) do
    cap = DateTime.add(now, @max_days, :day)

    cond do
      not DateTime.after?(period_end, now) -> {:error, :no_paid_period}
      DateTime.before?(period_end, cap) -> {:ok, period_end, "period_end"}
      true -> {:ok, cap, "max_days"}
    end
  end

  @doc "Lit la clé d'idempotence et la révision d'une requête rejouée, ou `nil` sans clé."
  def replay_params(params) do
    case {params["idempotency_key"], params["revision"]} do
      {nil, nil} ->
        {:ok, nil}

      {nil, _revision} ->
        invalid(:idempotency_key, "is required with a revision")

      {key, revision} ->
        with {:ok, key} <- key(key),
             {:ok, revision} <- revision(revision),
             do: {:ok, %{key: key, revision: revision}}
    end
  end

  defp key(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, key} -> {:ok, key}
      :error -> invalid(:idempotency_key, "must be a UUID")
    end
  end

  defp key(_value), do: invalid(:idempotency_key, "must be a UUID")

  defp revision(nil), do: {:ok, nil}
  defp revision(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp revision(_value), do: invalid(:revision, "must be a positive integer")

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}

  @doc "Réponse rejouée : `{:ok, response, replayed?}` (clés en chaînes) ou une erreur."
  def submit(user_id, %Lesson{} = lesson, answer, replay) do
    once(user_id, replay, lesson, "submit", answer, fn current ->
      with {:ok, result} <- Grader.grade(current, answer, user_id),
           {:ok, xp} <- Progress.record_submit(user_id, current, result.correct),
           do: {:ok, result |> Map.put(:xp, xp) |> Map.put(:xp_reward, current.xp_reward)}
    end)
  end

  @doc "Leçon terminée (`story`, `video`) rejouée, comme `submit/4`."
  def complete(user_id, %Lesson{} = lesson, params, replay) do
    once(user_id, replay, lesson, "complete", "", fn current ->
      with :ok <- if(current.kind == "video", do: Video.completion(params), else: :ok),
           {:ok, xp} <- Progress.record_complete(user_id, current),
           do: {:ok, %{xp: xp, xp_reward: current.xp_reward}}
    end)
  end

  defp once(
         user_id,
         %{key: key, revision: revision},
         %Lesson{id: lesson_id},
         action,
         request,
         fun
       ) do
    hash = request_hash(action, lesson_id, request)

    Repo.transact(fn ->
      case claim(user_id, key, lesson_id, action, hash) do
        :claimed ->
          with {:ok, current} <- locked(lesson_id),
               :ok <- same_revision(current, revision),
               {:ok, response} <- fun.(current) do
            response = response |> Jason.encode!() |> Jason.decode!()

            Repo.update_all(from(a in Action, where: a.user_id == ^user_id and a.key == ^key),
              set: [response: response]
            )

            {:ok, {response, false}}
          end

        %Action{lesson_id: ^lesson_id, action: ^action, request_hash: ^hash} = receipt ->
          {:ok, {receipt.response, true}}

        %Action{} ->
          {:error, :idempotency_key_reused}
      end
    end)
    |> case do
      {:ok, {response, replayed?}} ->
        # badges et quêtes : après validation, seulement pour une XP réellement accordée maintenant
        if not replayed? and response["xp"] == "awarded",
          do: Progress.after_progress({:ok, :awarded}, user_id)

        {:ok, response, replayed?}

      error ->
        error
    end
  end

  # La première requête insère le reçu (vide) ; une requête concurrente de même clé attend sa validation (index
  # unique) puis le lit.
  defp claim(user_id, key, lesson_id, action, hash) do
    row = %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      key: key,
      lesson_id: lesson_id,
      action: action,
      request_hash: hash,
      response: %{},
      inserted_at: DateTime.utc_now(:second)
    }

    case Repo.insert_all(Action, [row], on_conflict: :nothing, conflict_target: [:user_id, :key]) do
      {1, _} -> :claimed
      {0, _} -> Repo.one!(from a in Action, where: a.user_id == ^user_id and a.key == ^key)
    end
  end

  # la leçon telle qu'elle est corrigée : verrouillée jusqu'à la fin de la transaction (aucun import ne la change)
  defp locked(lesson_id) do
    case Repo.one(
           from l in Lesson,
             where: l.id == ^lesson_id,
             lock: "FOR SHARE",
             preload: [chapter: :adventure]
         ) do
      %Lesson{} = lesson -> {:ok, lesson}
      nil -> {:error, :not_found}
    end
  end

  defp same_revision(_lesson, nil), do: :ok
  defp same_revision(%Lesson{revision: revision}, revision), do: :ok

  defp same_revision(%Lesson{revision: current}, _revision),
    do: {:error, {:lesson_changed, current}}

  defp request_hash(action, lesson_id, request),
    do: Base.encode16(:crypto.hash(:sha256, [action, 0, lesson_id, 0, request]), case: :lower)
end
