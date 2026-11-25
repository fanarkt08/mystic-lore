defmodule MlAccounts.Incidents do
  @moduledoc """
  Incidents suivis par le staff, avec leur chronologie et un résumé obligatoire à la résolution.
  Chaque action est auditée dans la même transaction.
  """
  import Ecto.Query
  alias MlAccounts.{Audit, Incident, IncidentUpdate, Repo, Staff, User}
  import MlAccounts.Sanctions, only: [trimmed: 1, check_text: 4]

  @per_page 20

  @doc "Incidents (non résolus d'abord, puis les plus récents), `status` facultatif, 20 par page."
  def list(params) do
    page = Staff.page(params["page"])

    query =
      if params["status"] in Incident.statuses(),
        do: from(i in Incident, where: i.status == ^params["status"]),
        else: Incident

    total = Repo.aggregate(query, :count)

    entries =
      Repo.all(
        from i in query,
          order_by: [asc: fragment("? = 'resolved'", i.status), desc: i.inserted_at],
          limit: @per_page,
          offset: ^((page - 1) * @per_page)
      )

    %{
      entries: entries,
      page: page,
      total: total,
      total_pages: max(div(total + @per_page - 1, @per_page), 1)
    }
  end

  def get(id) do
    with {:ok, id} <- cast_id(id),
         %Incident{} = incident <- Repo.get(Incident, id) do
      {:ok, Repo.preload(incident, :updates)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Ouvre un incident ; `body` (facultatif) devient la première entrée de la chronologie."
  def open(%User{} = staff, params) do
    title = params["title"] |> trimmed() |> collapse()
    body = trimmed(params["body"])
    severity = params["severity"]

    with :ok <- check_text(:title, title, 3, 140),
         :ok <- severity_ok(severity),
         :ok <- if(body, do: check_text(:body, body, 3, 2000), else: :ok) do
      Repo.transact(fn ->
        incident =
          Repo.insert!(%Incident{title: title, severity: severity, created_by: staff.id})

        if body,
          do:
            Repo.insert!(%IncidentUpdate{
              incident_id: incident.id,
              author_id: staff.id,
              body: body,
              status: "open",
              severity: severity
            })

        Audit.record!(staff.id, "incident.opened", "incident", incident.id, nil, %{
          "severity" => severity
        })

        {:ok, Repo.preload(incident, :updates)}
      end)
    end
  end

  @doc "Ajoute une mise à jour à un incident et change éventuellement son statut ou sa sévérité."
  def add_update(%User{} = staff, id, params) do
    body = trimmed(params["body"])
    status = params["status"] |> trimmed()
    severity = params["severity"] |> trimmed()
    summary = trimmed(params["summary"])

    with :ok <- check_text(:body, body, 3, 2000),
         :ok <- status_ok(status),
         :ok <- if(severity, do: severity_ok(severity), else: :ok),
         :ok <- if(status == "resolved", do: check_text(:summary, summary, 10, 2000), else: :ok),
         {:ok, id} <- cast_id(id) do
      Repo.transact(fn ->
        with %Incident{} = incident <-
               Repo.one(from i in Incident, where: i.id == ^id, lock: "FOR UPDATE") ||
                 {:error, :not_found},
             :ok <- if(incident.status == "resolved", do: {:error, :already_resolved}, else: :ok) do
          apply_update(staff, incident, body, status, severity, summary)
        end
      end)
    end
  end

  defp apply_update(staff, incident, body, status, severity, summary) do
    changes =
      [status: status, severity: severity]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Kernel.++(
        if status == "resolved",
          do: [summary: summary, resolved_by: staff.id, resolved_at: DateTime.utc_now(:second)],
          else: []
      )

    incident = incident |> Ecto.Changeset.change(changes) |> Repo.update!(force: true)

    Repo.insert!(%IncidentUpdate{
      incident_id: incident.id,
      author_id: staff.id,
      body: body,
      status: status,
      severity: severity
    })

    action = if status == "resolved", do: "incident.resolved", else: "incident.updated"

    Audit.record!(staff.id, action, "incident", incident.id, nil, %{
      "status" => incident.status,
      "severity" => incident.severity
    })

    {:ok, Repo.preload(incident, :updates, force: true)}
  end

  defp severity_ok(severity) do
    if severity in Incident.severities(),
      do: :ok,
      else: {:error, {:invalid, %{severity: ["is invalid"]}}}
  end

  defp status_ok(nil), do: :ok

  defp status_ok(status) do
    if status in Incident.statuses(),
      do: :ok,
      else: {:error, {:invalid, %{status: ["is invalid"]}}}
  end

  defp collapse(nil), do: nil
  defp collapse(title), do: String.replace(title, ~r/\s+/u, " ")

  defp cast_id(id) do
    with :error <- Ecto.UUID.cast(id), do: {:error, :not_found}
  end
end
