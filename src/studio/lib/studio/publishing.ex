defmodule MlStudio.Publishing do
  @moduledoc """
  From draft to the learning catalog: checks and attestations, submission, staff review and import.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias MlStudio.{Events, Projects, Repo, Services, View}
  alias MlStudio.Projects.{Collaborator, Project, Version}
  alias MlStudio.Publishing.{Checks, ImportWorker}

  @attestations ~w(accuracy safety accessibility)

  def checks(user_id, project_id) do
    with {:ok, project, _role} <- Projects.access(user_id, project_id, :view) do
      project = Projects.load(project)
      checks = Checks.run(Projects.snapshot(project))

      {:ok,
       %{
         "checks" => checks,
         "ready" => Checks.ok?(checks),
         "attestations" => View.attestations(project)
       }}
    end
  end

  @doc "The owner's declarations, for the current content revision."
  def attest(user_id, project_id, params) do
    Repo.transact(fn ->
      with {:ok, project, _role} <- Projects.access(user_id, project_id, :owner, lock: true),
           :ok <- Projects.editable(project) do
        project
        |> Changeset.change(
          attestations: Map.new(@attestations, &{&1, params[&1] == true}),
          attested_revision: project.content_revision,
          attested_at: now()
        )
        |> Repo.update()
      end
    end)
  end

  def submit(user_id, project_id) do
    Repo.transact(fn ->
      with {:ok, project, _role} <- Projects.access(user_id, project_id, :owner, lock: true),
           :ok <- status(project, "draft", :not_draft),
           project = Projects.load(project),
           checks = Checks.run(Projects.snapshot(project)),
           :ok <- if(Checks.ok?(checks), do: :ok, else: {:error, {:checks_failed, checks}}),
           :ok <-
             if(View.attestations(project)["valid"],
               do: :ok,
               else: {:error, :attestations_required}
             ) do
        version = Projects.insert_version(project, user_id, "submission", "Submitted for review")

        project
        |> Changeset.change(
          status: "submitted",
          review_version: version.number,
          submitted_at: now(),
          review_reason: nil,
          reviewed_by: nil,
          reviewed_at: nil,
          import_message: nil
        )
        |> Repo.update()
      end
    end)
    |> broadcast(user_id)
  end

  def withdraw(user_id, project_id) do
    Repo.transact(fn ->
      with {:ok, project, _role} <- Projects.access(user_id, project_id, :owner, lock: true),
           :ok <- status(project, "submitted", :not_submitted) do
        project |> Changeset.change(status: "draft") |> Repo.update()
      end
    end)
    |> broadcast(user_id)
  end

  ## Staff review (drafts are never visible here)

  def queue(user_id) do
    with :ok <- staff(user_id) do
      {:ok,
       Repo.all(
         from p in Project,
           where: p.status in ["submitted", "approved"],
           order_by: [asc: p.submitted_at]
       )}
    end
  end

  @doc "The submitted snapshot, its checks and the author's declarations (also once published)."
  def review(user_id, project_id) do
    with :ok <- staff(user_id),
         {:ok, project} <- in_review(project_id, published: true) do
      version = Repo.get_by!(Version, project_id: project.id, number: project.review_version)

      {:ok,
       %{
         project: project,
         version: version,
         checks: Checks.run(version.snapshot),
         attestations: View.attestations(project)
       }}
    end
  end

  def approve(user_id, project_id) do
    with :ok <- staff(user_id) do
      Repo.transact(fn ->
        with {:ok, project} <- in_review(project_id, lock: true),
             :ok <- not_author(project, user_id),
             :ok <- status(project, "submitted", :not_submitted) do
          project =
            project
            |> Changeset.change(status: "approved", reviewed_by: user_id, reviewed_at: now())
            |> Changeset.change(review_reason: nil, import_message: nil)
            |> Repo.update!()

          Oban.insert!(
            ImportWorker.new(%{project_id: project.id, version: project.review_version})
          )

          with :ok <- audit(user_id, "studio.project.approved", project, nil),
               :ok <- MlStudio.NotifyWorker.enqueue!(project, "review_approved"),
               do: {:ok, project}
        end
      end)
      |> broadcast(user_id)
    end
  end

  def reject(user_id, project_id, params) do
    with :ok <- staff(user_id),
         {:ok, reason} <- reason(params["reason"]) do
      Repo.transact(fn ->
        with {:ok, project} <- in_review(project_id, lock: true),
             :ok <- not_author(project, user_id),
             :ok <- status(project, "submitted", :not_submitted) do
          project =
            project
            |> Changeset.change(status: "draft", review_reason: reason)
            |> Changeset.change(reviewed_by: user_id, reviewed_at: now())
            |> Repo.update!()

          with :ok <- audit(user_id, "studio.project.rejected", project, reason),
               :ok <- MlStudio.NotifyWorker.enqueue!(project, "review_rejected"),
               do: {:ok, project}
        end
      end)
      |> broadcast(user_id)
    end
  end

  @doc "Staff: enqueue the import of an approved project again."
  def retry_import(user_id, project_id) do
    with :ok <- staff(user_id),
         {:ok, project} <- in_review(project_id),
         :ok <- status(project, "approved", :not_approved) do
      Repo.transact(fn ->
        Oban.insert!(ImportWorker.new(%{project_id: project.id, version: project.review_version}))

        with :ok <- audit(user_id, "studio.project.import_retried", project, nil),
             do: {:ok, project}
      end)
    end
  end

  # Central audit entry (accounts) of a staff decision, inside its transaction.
  defp audit(user_id, action, project, reason),
    do:
      Services.audit(user_id, action, project.id, reason, %{
        "owner_id" => project.owner_id,
        "version" => project.review_version
      })

  @doc "Staff indicators: projects waiting for review, AI generations that failed in the last 24 hours."
  def stats(user_id, now \\ DateTime.utc_now()) do
    with :ok <- staff(user_id) do
      {:ok,
       %{
         review_queue: Repo.aggregate(from(p in Project, where: p.status == "submitted"), :count),
         failed_generations_24h:
           Repo.aggregate(
             from(g in MlStudio.AI.Generation,
               where: g.status == "failed" and g.updated_at > ^DateTime.add(now, -1, :day)
             ),
             :count
           )
       }}
    end
  end

  ## Import (called by ImportWorker)

  @doc "Body of learning `POST /api/internal/adventures/import` for an approved version."
  def import_payload(%Project{} = project, %Version{number: number, snapshot: s}) do
    b = s["brief"]
    media = Map.new(s["media"] || [], &{&1["id"], &1})

    %{
      "external_id" => project.id,
      "version" => number,
      "adventure" => %{
        "title" => b["title"],
        "summary" => b["summary"],
        "description" => b["description"],
        "category" => b["category"],
        "difficulty" => b["level"],
        "duration_minutes" => b["duration_minutes"],
        "objectives" => b["objectives"],
        "prerequisites" => b["prerequisites"],
        "cover" => b["cover"],
        "author_id" => project.owner_id,
        "premium" => false,
        "chapters" =>
          for(
            m <- s["modules"],
            do: %{"title" => m["title"], "lessons" => Enum.map(m["lessons"], &lesson(&1, media))}
          )
      }
    }
  end

  defp lesson(l, media) do
    base = Map.take(l, ["title", "kind", "body", "xp_reward"])
    c = l["content"]

    case l["kind"] do
      "video" ->
        Map.put(base, "content", %{
          "video" => %{
            "media_id" => c["video_id"],
            "content_type" => media[c["video_id"]]["content_type"]
          },
          "captions" => c["captions"],
          "transcript" => c["transcript"],
          "duration_s" => c["duration_s"]
        })

      "simulation" ->
        {content, solution} = simulation(c)
        Map.merge(base, %{"content" => content, "solution" => solution})

      "minigame" ->
        game = Map.take(c, ["game", "prompt"])

        content =
          if c["game"] == "constellation",
            do: Map.merge(game, Map.take(c, ["stars", "path"])),
            else: Map.put(game, "items", c["items"])

        Map.put(base, "content", content)

      "exercise" ->
        Map.merge(base, %{
          "content" => %{"question" => c["question"], "choices" => c["choices"]},
          "solution" => c["answer"],
          "explanation" => c["explanation"]
        })

      "coding" ->
        Map.put(base, "content", Map.take(c, ["plants", "starter", "hints"]))

      _story ->
        base
    end
  end

  # learning's simulation config from the author's form
  defp simulation(%{"model" => "orbit"} = c) do
    param = fn range, label, unit -> Map.merge(range, %{"label" => label, "unit" => unit}) end

    {%{
       "model" => "orbit",
       "goal_text" => c["goal_text"],
       "steps" => c["steps"],
       "params" => %{
         "velocity" => param.(c["velocity"], "Launch speed", "AU/yr"),
         "star_mass" => param.(c["star_mass"], "Star mass", "M☉")
       },
       "fixed" => %{"distance" => c["distance"], "dt" => c["dt"], "planet_mass" => 0.001}
     }, %{"max_eccentricity" => c["max_eccentricity"], "min_revolutions" => c["min_revolutions"]}}
  end

  defp simulation(%{"model" => "reaction"} = c) do
    species =
      for {s, i} <- Enum.with_index(c["species"] || [], 1),
          do: %{
            "key" => "s#{i}",
            "formula" => s["formula"],
            "side" => s["side"],
            "initial" => s["initial"]
          }

    {%{
       "model" => "reaction",
       "goal_text" => c["goal_text"],
       "steps" => c["steps"],
       "yield_pct" => c["yield_pct"],
       "species" => species,
       "params" =>
         Map.new(species, fn s ->
           {s["key"], %{"min" => 1, "max" => c["max_coefficient"], "step" => 1, "default" => 1}}
         end)
     }, %{"lowest_terms" => c["lowest_terms"]}}
  end

  @doc false
  def import_result(%Project{} = project, result) do
    changes =
      case result do
        {:published, %{"slug" => slug} = body} ->
          [
            status: "published",
            published_slug: slug,
            published_adventure_id: to_string(body["adventure_id"]),
            published_version: project.review_version,
            published_at: now(),
            import_message: nil
          ]

        {:pending, message} ->
          [import_message: message]
      end

    from(p in Project, where: p.id == ^project.id and p.status == "approved", select: p)
    |> Repo.update_all(set: changes)
    |> case do
      {1, [updated]} ->
        Events.project_changed(updated, nil)
        updated

      {0, _} ->
        project
    end
  end

  ## Helpers

  defp staff(user_id) do
    case Services.staff?(user_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :forbidden}
      {:error, _} -> {:error, :accounts_unavailable}
    end
  end

  defp in_review(project_id, opts \\ []) do
    query = if opts[:lock], do: from(p in Project, lock: "FOR UPDATE"), else: Project

    visible =
      if opts[:published],
        do: ["submitted", "approved", "published"],
        else: ["submitted", "approved"]

    with {:ok, id} <- Ecto.UUID.cast(project_id),
         %Project{status: status} = project <- Repo.get(query, id),
         true <- status in visible do
      {:ok, project}
    else
      _ -> {:error, :not_found}
    end
  end

  # Authors (owner and editors) never review their own project.
  defp not_author(%Project{owner_id: user_id}, user_id), do: {:error, :own_project}

  defp not_author(project, user_id) do
    if Repo.exists?(
         from c in Collaborator,
           where: c.project_id == ^project.id and c.user_id == ^user_id and c.role == "editor"
       ),
       do: {:error, :own_project},
       else: :ok
  end

  defp status(%Project{status: status}, status, _error), do: :ok
  defp status(_project, _status, error), do: {:error, error}

  defp reason(reason) when is_binary(reason) do
    reason = String.trim(reason)

    if String.length(reason) in 3..1000,
      do: {:ok, reason},
      else: {:error, {:invalid, %{reason: ["should be 3 to 1000 character(s)"]}}}
  end

  defp reason(_reason), do: {:error, {:invalid, %{reason: ["can't be blank"]}}}

  defp broadcast({:ok, project} = ok, user_id) do
    Events.project_changed(project, user_id)
    ok
  end

  defp broadcast(error, _user_id), do: error

  defp now, do: DateTime.utc_now(:second)
end
