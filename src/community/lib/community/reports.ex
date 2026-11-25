defmodule MlCommunity.Reports do
  @moduledoc """
  Signalements de discussions et de réponses, un seul ouvert par membre et par cible.
  Une cible invisible pour le membre reçoit la même réponse qu'un identifiant inconnu.
  """
  import Ecto.Changeset
  import Ecto.Query
  alias MlCommunity.{Discussion, Forum, Moderation, Reply, Report, Repo, Viewer}

  @per_page 20
  @resolutions ~w(dismiss hide remove)

  @doc "`{:ok, report}`, un changeset invalide (422) ou `{:error, :already_reported}`."
  def create(%Viewer{id: me} = viewer, attrs) do
    changeset = Report.changeset(%Report{reporter_id: me}, attrs)

    with {:ok, changeset} <- with_snapshot(changeset, viewer) do
      case Repo.insert(changeset) do
        {:error, %{errors: errors} = changeset} ->
          if Enum.any?(errors, fn {_, {_, opts}} -> opts[:constraint] == :unique end),
            do: {:error, :already_reported},
            else: {:error, changeset}

        ok ->
          ok
      end
    end
  end

  defp with_snapshot(%{valid?: false} = changeset, _viewer), do: {:error, changeset}

  defp with_snapshot(changeset, %Viewer{id: me} = viewer) do
    case target(viewer, get_field(changeset, :target_type), get_field(changeset, :target_id)) do
      {:ok, %{author_id: ^me}, _discussion} ->
        {:error, add_error(changeset, :target_id, "cannot be your own content")}

      {:ok, post, discussion} ->
        {:ok, put_change(changeset, :snapshot, snapshot(post, discussion))}

      {:error, :not_found} ->
        {:error, add_error(changeset, :target_id, "is invalid")}
    end
  end

  defp target(viewer, "discussion", id) do
    with {:ok, discussion} <- Forum.fetch_discussion_by_id(viewer, id),
         do: {:ok, discussion, discussion}
  end

  defp target(viewer, "reply", id) do
    with {:ok, reply} <- Forum.fetch_reply(viewer, id), do: {:ok, reply, reply.discussion}
  end

  defp snapshot(post, discussion) do
    %{
      "title" => discussion.title,
      "body" => post.body,
      "author_id" => post.author_id,
      "discussion_id" => discussion.id,
      "discussion_slug" => discussion.slug,
      "status" => post.status,
      "posted_at" => DateTime.to_iso8601(post.inserted_at)
    }
  end

  ## Staff

  @doc "Signalements ouverts, les plus anciens d'abord, avec le statut actuel de leur cible (`target_status`)."
  def list_open(page) do
    from(r in Report, as: :report, where: r.status == "open")
    |> MlCommunity.paginate(page, @per_page, fn query ->
      query |> order_by([report: r], asc: r.inserted_at, asc: r.id) |> with_target_status()
    end)
  end

  @doc "Un signalement (ouvert ou résolu) avec le statut actuel de sa cible."
  def get(report_id) do
    with {:ok, id} <- cast_id(report_id),
         %Report{} = report <-
           from(r in Report, as: :report, where: r.id == ^id)
           |> with_target_status()
           |> Repo.one() do
      {:ok, report}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Indicateurs réels : discussions et réponses publiées en 7 jours, signalements ouverts."
  def stats(now \\ DateTime.utc_now()) do
    week_ago = DateTime.add(now, -7, :day)

    %{
      discussions_7d:
        Repo.aggregate(from(d in Discussion, where: d.inserted_at > ^week_ago), :count),
      replies_7d: Repo.aggregate(from(r in Reply, where: r.inserted_at > ^week_ago), :count),
      open_reports: Repo.aggregate(from(r in Report, where: r.status == "open"), :count)
    }
  end

  @doc "`{:ok, report}` ou `{:error, :not_found | :already_resolved | :conflict | {:invalid, errors}}`."
  def resolve(staff_id, report_id, params) do
    action = params["action"]
    reason = MlCommunity.trimmed(params["reason"])

    cond do
      action not in @resolutions ->
        {:error, {:invalid, %{action: ["is invalid"]}}}

      action != "dismiss" and is_nil(reason) ->
        {:error, {:invalid, %{reason: ["can't be blank"]}}}

      true ->
        with {:ok, id} <- cast_id(report_id),
             {:ok, _report} <-
               Repo.transact(fn -> resolve_locked(id, staff_id, action, reason) end) do
          report = from(r in Report, as: :report, where: r.id == ^id)
          {:ok, report |> with_target_status() |> Repo.one!()}
        end
    end
  end

  defp resolve_locked(id, staff_id, action, reason) do
    with {:ok, report} <- lock_open(id),
         :ok <- moderate_target(report, staff_id, action, reason) do
      # Masquer ou retirer la cible règle aussi les autres signalements ouverts sur elle.
      scope =
        if action == "dismiss",
          do: from(r in Report, where: r.id == ^report.id),
          else:
            from(r in Report,
              where:
                r.status == "open" and r.target_type == ^report.target_type and
                  r.target_id == ^report.target_id
            )

      Repo.update_all(scope,
        set: [
          status: "resolved",
          resolution: action,
          resolution_reason: reason,
          resolved_by: staff_id,
          resolved_at: DateTime.utc_now()
        ]
      )

      with {:ok, _entry} <-
             Moderation.log(staff_id, "resolve_report", "report", report.id, reason, %{
               "action" => action
             }),
           do: {:ok, report}
    end
  end

  defp lock_open(id) do
    case Repo.one(from r in Report, where: r.id == ^id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      %Report{status: "open"} = report -> {:ok, report}
      %Report{} -> {:error, :already_resolved}
    end
  end

  defp moderate_target(_report, _staff_id, "dismiss", _reason), do: :ok

  defp moderate_target(report, staff_id, action, reason) do
    type = if report.target_type == "discussion", do: :discussion, else: :reply

    Moderation.act(staff_id, type, report.target_id, %{"action" => action, "reason" => reason})
  end

  # `query` porte la liaison nommée `:report`.
  defp with_target_status(query) do
    query
    |> join(:left, [report: r], d in Discussion,
      as: :discussion,
      on: r.target_type == "discussion" and d.id == r.target_id
    )
    |> join(:left, [report: r], p in Reply,
      as: :reply,
      on: r.target_type == "reply" and p.id == r.target_id
    )
    |> select_merge([discussion: d, reply: p], %{target_status: coalesce(d.status, p.status)})
  end

  defp cast_id(id) do
    with :error <- Ecto.UUID.cast(id), do: {:error, :not_found}
  end
end
