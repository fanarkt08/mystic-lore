defmodule MlStudio.AI do
  @moduledoc """
  AI generations, run by Oban and paid with billing credits reserved before the job starts.
  In production a missing API key refuses generations instead of simulating them.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias MlStudio.{Events, Images, Projects, Repo, Services}

  alias MlStudio.AI.{
    Anthropic,
    Deterministic,
    Generation,
    GenerationWorker,
    Prompt,
    SettleWorker,
    Setting
  }

  alias MlStudio.Projects.{CourseModule, Lesson}

  @retryable [:rate_limited, :overloaded, :provider_unavailable, :timeout]
  @max_running 5

  def costs, do: Application.fetch_env!(:studio, :ai_costs)

  def provider do
    case Application.get_env(:studio, :ai_provider) do
      "anthropic" -> Anthropic
      "demo" -> Deterministic
      _ -> if Anthropic.configured?() or prod?(), do: Anthropic, else: Deterministic
    end
  end

  defp prod?, do: Application.get_env(:studio, :env) == :prod
  defp provider("anthropic"), do: Anthropic
  defp provider(_demo), do: Deterministic

  @doc "What the studio can do for this member (provider, costs, consent)."
  def info(user_id) do
    p = provider()

    %{
      "provider" => p.name(),
      "demo" => p == Deterministic,
      "label" => if(p == Deterministic, do: Deterministic.label()),
      "configured" => p.configured?(),
      "model" => p.model(),
      "external" => p.external?(),
      "image_generation" => p.images?(),
      "costs" => costs(),
      "share_drafts_with_ai" => consent?(user_id)
    }
  end

  # projet sans propriétaire (compte supprimé) : aucun consentement
  def consent?(nil), do: false

  def consent?(user_id),
    do:
      Repo.one(from s in Setting, where: s.user_id == ^user_id, select: s.share_drafts_with_ai) ==
        true

  def set_consent(user_id, %{"share_drafts_with_ai" => value}) when is_boolean(value) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      %Setting{user_id: user_id, share_drafts_with_ai: value, inserted_at: now, updated_at: now},
      on_conflict: [set: [share_drafts_with_ai: value, updated_at: now]],
      conflict_target: :user_id
    )

    {:ok, value}
  end

  def set_consent(_user_id, _params),
    do: {:error, {:invalid, %{share_drafts_with_ai: ["must be true or false"]}}}

  ## Generations

  def create(user_id, project_id, params, retry_of \\ nil) do
    provider = provider()

    with {:ok, project, _role} <- Projects.access(user_id, project_id, :edit),
         :ok <- Projects.editable(project),
         {:ok, attrs} <- validate(project, params),
         :ok <- available(provider, attrs.kind),
         cost = Map.fetch!(costs(), attrs.kind),
         :ok <- confirmed(params["confirm_cost"], cost),
         :ok <- not_too_many(user_id),
         :ok <- vip(user_id, attrs.kind) do
      generation = %Generation{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        lesson_id: attrs.lesson_id,
        user_id: user_id,
        kind: attrs.kind,
        cost: cost,
        provider: provider.name(),
        model: provider.model(),
        brief: attrs.brief,
        retry_of: retry_of
      }

      with {:ok, _held} <- Services.reserve(user_id, cost, Generation.ref(generation), attrs.kind) do
        enqueue(generation)
      end
    end
  end

  defp enqueue(generation) do
    Repo.transact(fn ->
      with {:ok, generation} <- Repo.insert(generation) do
        Oban.insert!(GenerationWorker.new(%{generation_id: generation.id}))
        {:ok, generation}
      end
    end)
    |> case do
      {:ok, generation} ->
        Events.generation(generation)
        {:ok, generation}

      error ->
        Services.settle(generation.user_id, Generation.ref(generation), :release)
        error
    end
  end

  def list(user_id, project_id) do
    with {:ok, project, _role} <- Projects.access(user_id, project_id, :view) do
      {:ok,
       Repo.all(
         from g in Generation,
           where: g.project_id == ^project.id,
           order_by: [desc: g.inserted_at],
           limit: 30
       )}
    end
  end

  @doc "The member's own generations, newest first (20 per page), with the project title."
  def history(user_id, page) do
    query = from g in Generation, where: g.user_id == ^user_id
    total = Repo.aggregate(query, :count)

    entries =
      Repo.all(
        from g in query,
          join: p in assoc(g, :project),
          order_by: [desc: g.inserted_at],
          limit: 20,
          offset: ^((page - 1) * 20),
          select: {g, p.title}
      )

    %{entries: entries, page: page, total: total, total_pages: max(div(total + 19, 20), 1)}
  end

  def cancel(user_id, generation_id) do
    with {:ok, generation} <- editable_generation(user_id, generation_id) do
      Repo.transact(fn ->
        case from(g in Generation,
               where: g.id == ^generation.id and g.status in ["pending", "running"],
               select: g
             )
             |> Repo.update_all(set: [status: "cancelled", finished_at: now(), updated_at: now()]) do
          {1, [cancelled]} ->
            Oban.insert!(SettleWorker.new(%{generation_id: cancelled.id}))
            {:ok, cancelled}

          {0, _} ->
            {:error, :not_cancellable}
        end
      end)
      |> case do
        {:ok, cancelled} ->
          # stops the provider call if it is running (the job would discard its result anyway)
          Oban.cancel_all_jobs(
            from j in Oban.Job,
              where:
                j.worker == "MlStudio.AI.GenerationWorker" and
                  j.args["generation_id"] == ^cancelled.id
          )

          Events.generation(cancelled)
          {:ok, cancelled}

        error ->
          error
      end
    end
  end

  @doc "A failed or cancelled generation again: a new generation (new reservation, cost confirmed again)."
  def retry(user_id, generation_id, params) do
    with {:ok, generation} <- editable_generation(user_id, generation_id),
         :ok <-
           if(generation.status in ["failed", "cancelled"],
             do: :ok,
             else: {:error, :not_retryable}
           ) do
      create(
        user_id,
        generation.project_id,
        %{
          "kind" => generation.kind,
          "lesson_id" => generation.lesson_id,
          "brief" => generation.brief,
          "confirm_cost" => params["confirm_cost"]
        },
        generation.id
      )
    end
  end

  @doc "Writes a succeeded result into the project (once)."
  def apply(user_id, generation_id) do
    with {:ok, generation} <- editable_generation(user_id, generation_id),
         :ok <-
           if(generation.status == "succeeded" and generation.kind != "image",
             do: :ok,
             else: {:error, :not_applicable}
           ) do
      Projects.change_content(user_id, generation.project_id, :edit, fn project, _role ->
        case from(g in Generation,
               where: g.id == ^generation.id and is_nil(g.applied_at),
               select: g
             )
             |> Repo.update_all(set: [applied_at: now()]) do
          {1, [applied]} -> with :ok <- write(project, applied), do: {:ok, applied}
          {0, _} -> {:error, :already_applied}
        end
      end)
      |> case do
        {:ok, applied} ->
          Events.generation(applied)
          {:ok, applied}

        error ->
          error
      end
    end
  end

  defp write(project, %Generation{kind: "outline", result: %{"modules" => modules}}) do
    first =
      (Repo.one(
         from m in CourseModule, where: m.project_id == ^project.id, select: max(m.position)
       ) || 0) + 1

    room = max(20 - first + 1, 0)

    for {m, i} <- modules |> Enum.take(room) |> Enum.with_index(first) do
      module = Repo.insert!(%CourseModule{project_id: project.id, position: i, title: m["title"]})

      for {l, j} <- Enum.with_index(m["lessons"], 1) do
        %Lesson{project_id: project.id, module_id: module.id, position: j}
        |> Lesson.create_changeset(%{
          "title" => l["title"],
          "kind" => l["kind"],
          "body" => l["summary"]
        })
        |> Repo.insert!()
      end
    end

    :ok
  end

  defp write(project, %Generation{kind: kind, lesson_id: lesson_id, result: result})
       when kind in ["lesson_draft", "feedback"] do
    with {:ok, lesson} <- target(project, lesson_id) do
      attrs =
        if kind == "feedback",
          do: %{"content" => %{"explanation" => result["explanation"]}},
          else: %{"body" => result["body"], "content" => result["content"]}

      lesson
      |> Lesson.update_changeset(Map.put(attrs, "title", lesson.title))
      |> Changeset.put_change(:lock_version, lesson.lock_version + 1)
      |> Repo.update!()

      :ok
    end
  end

  defp target(_project, nil), do: {:error, :target_missing}

  defp target(project, lesson_id) do
    case Projects.lesson(project, lesson_id) do
      {:ok, lesson} -> {:ok, lesson}
      _ -> {:error, :target_missing}
    end
  end

  ## Job side (GenerationWorker / SettleWorker)

  @doc false
  def run(%Generation{} = generation, last_attempt?) do
    case mark(generation, ["pending", "running"],
           status: "running",
           started_at: generation.started_at || now()
         ) do
      {:ok, running} ->
        Events.generation(running)
        running |> execute() |> finish(running, last_attempt?)

      {:error, :stale} ->
        :ok
    end
  end

  defp execute(generation) do
    provider = provider(generation.provider)
    project = Projects.Project |> Repo.get!(generation.project_id) |> Projects.load()

    share? =
      not provider.external?() or (consent?(generation.user_id) and consent?(project.owner_id))

    request = Prompt.request(generation, project, share?)

    if generation.kind == "image" do
      provider.generate_image(request)
    else
      with {:ok, output} <- provider.generate(request),
           do: Prompt.validate(generation.kind, request.lesson_kind, output)
    end
  end

  # Every transition is conditional: a generation cancelled meanwhile keeps its status and the
  # result is discarded (the cancellation already enqueued the release of its credits).
  defp finish({:ok, result}, generation, _last?) do
    Repo.transact(fn ->
      with {:ok, done} <-
             mark(generation, ["running"], status: "succeeded", error: nil, finished_at: now()) do
        result =
          if generation.kind == "image",
            do: %{
              "image_id" =>
                Images.store_generated(done.project_id, done.lesson_id, done.user_id, result).id
            },
            else: result

        done = done |> Changeset.change(result: result) |> Repo.update!()
        Oban.insert!(SettleWorker.new(%{generation_id: done.id}))
        {:ok, done}
      end
    end)
    |> published()
  end

  defp finish({:error, reason}, generation, last?) when reason in @retryable and not last? do
    case mark(generation, ["running"], status: "pending", error: Atom.to_string(reason)) do
      {:ok, waiting} ->
        Events.generation(waiting)
        {:error, reason}

      {:error, :stale} ->
        :ok
    end
  end

  defp finish({:error, reason}, generation, _last?) do
    Repo.transact(fn ->
      with {:ok, failed} <-
             mark(generation, ["running"],
               status: "failed",
               error: Atom.to_string(reason),
               finished_at: now()
             ) do
        Oban.insert!(SettleWorker.new(%{generation_id: failed.id}))
        {:ok, failed}
      end
    end)
    |> published()
  end

  defp published({:ok, generation}) do
    Events.generation(generation)
    :ok
  end

  defp published({:error, :stale}), do: :ok

  @doc false
  def settle(%Generation{} = generation) do
    operation = if generation.status == "succeeded", do: :consume, else: :release

    state =
      case Services.settle(generation.user_id, Generation.ref(generation), operation) do
        {:ok, %{"status" => status}} when status in ["consumed", "released"] -> status
        {:error, {:http, 409, %{"error" => "already_" <> status}}} -> status
        {:error, {:http, 404, _}} -> :missing
        _ -> :unavailable
      end

    case state do
      :unavailable ->
        {:error, :credits_unavailable}

      :missing ->
        {:cancel, :reservation_not_found}

      status ->
        with {:ok, settled} <-
               mark(generation, ["succeeded", "failed", "cancelled"], [credits: status],
                 credits: "reserved"
               ),
             do: Events.generation(settled)

        :ok
    end
  end

  # Conditional transition: only from the given statuses (and `extra` field values).
  defp mark(generation, from, changes, extra \\ []) do
    query = from g in Generation, where: g.id == ^generation.id and g.status in ^from, select: g

    query =
      Enum.reduce(extra, query, fn {name, value}, q ->
        where(q, [g], field(g, ^name) == ^value)
      end)

    case Repo.update_all(query, set: Keyword.put(changes, :updated_at, now())) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :stale}
    end
  end

  ## Validation

  defp validate(project, params) do
    kind = params["kind"]
    brief = String.trim(to_string(params["brief"] || ""))

    cond do
      kind not in Generation.kinds() ->
        invalid(:kind, "is invalid")

      brief == "" ->
        invalid(:brief, "can't be blank")

      String.length(brief) > 2_000 ->
        invalid(:brief, "should be at most 2000 character(s)")

      true ->
        with {:ok, lesson_id} <- lesson_for(project, kind, params["lesson_id"]),
             do: {:ok, %{kind: kind, brief: brief, lesson_id: lesson_id}}
    end
  end

  defp lesson_for(_project, "outline", _id), do: {:ok, nil}
  defp lesson_for(_project, "image", nil), do: {:ok, nil}

  defp lesson_for(project, kind, id) do
    case Projects.lesson(project, id) do
      {:ok, %{kind: lesson_kind}} when kind == "feedback" and lesson_kind != "exercise" ->
        invalid(:lesson_id, "must be a quiz lesson")

      # video, simulation and mini-game lessons need media or a model: written by hand only
      {:ok, %{kind: lesson_kind} = lesson} when kind == "lesson_draft" ->
        if lesson_kind in Lesson.ai_kinds(),
          do: {:ok, lesson.id},
          else: invalid(:lesson_id, "must be a story, quiz or coding lesson")

      {:ok, lesson} ->
        {:ok, lesson.id}

      {:error, :not_found} ->
        invalid(:lesson_id, "is invalid")
    end
  end

  defp available(provider, kind) do
    cond do
      not provider.configured?() -> {:error, :ai_not_configured}
      kind == "image" and not provider.images?() -> {:error, :image_generation_unavailable}
      true -> :ok
    end
  end

  defp confirmed(cost, cost), do: :ok
  defp confirmed(nil, _cost), do: invalid(:confirm_cost, "can't be blank")
  defp confirmed(_other, cost), do: {:error, {:cost_mismatch, cost}}

  defp not_too_many(user_id) do
    running =
      Repo.aggregate(
        from(g in Generation,
          where: g.user_id == ^user_id and g.status in ["pending", "running"]
        ),
        :count
      )

    if running < @max_running, do: :ok, else: {:error, :too_many_generations}
  end

  defp vip(user_id, "image") do
    case Services.plan(user_id) do
      {:ok, "vip"} -> :ok
      {:ok, _plan} -> {:error, :vip_required}
      {:error, _} -> {:error, :billing_unavailable}
    end
  end

  defp vip(_user_id, _kind), do: :ok

  defp editable_generation(user_id, generation_id) do
    with {:ok, id} <- Ecto.UUID.cast(generation_id),
         %Generation{} = generation <- Repo.get(Generation, id),
         {:ok, _project, _role} <- Projects.access(user_id, generation.project_id, :edit) do
      {:ok, generation}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
  defp now, do: DateTime.utc_now(:second)
end
