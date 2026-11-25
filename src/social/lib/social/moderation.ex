defmodule MlSocial.Moderation do
  @moduledoc """
  Traitement des signalements par le staff, sans aucune lecture libre des conversations.
  La seule preuve est l'instantané du message signalé, renvoyé après l'écriture de l'entrée d'audit.
  """
  import Ecto.Query
  alias MlShared.Client
  alias MlSocial.{Accounts, Attachment, Attachments, Delivery, Message, Repo, Report}

  @per_page 20
  @actions ~w(dismiss remove_message warn restrict)

  @doc "Signalements `open` (plus anciens d'abord) ou `resolved` (plus récents d'abord), 20 par page."
  def list(params) do
    status = if params["status"] == "resolved", do: "resolved", else: "open"
    page = page(params["page"])
    query = from r in Report, where: r.status == ^status
    total = Repo.aggregate(query, :count)
    order = if status == "open", do: [asc: :inserted_at, asc: :id], else: [desc: :resolved_at]

    entries =
      Repo.all(
        from r in query,
          order_by: ^order,
          limit: @per_page,
          offset: ^((page - 1) * @per_page)
      )

    %{
      entries: with_messages(entries),
      page: page,
      total: total,
      total_pages: max(div(total + @per_page - 1, @per_page), 1)
    }
  end

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Report{} = report <- Repo.get(Report, id) do
      {:ok, hd(with_messages([report]))}
    else
      _ -> {:error, :not_found}
    end
  end

  # état actuel du message signalé (retiré ou non), sans son texte
  defp with_messages(reports) do
    ids = for %Report{target_type: "message", target_id: id} <- reports, do: id

    removed =
      Repo.all(from m in Message, where: m.id in ^ids, select: {m.id, not is_nil(m.removed_at)})
      |> Map.new()

    Enum.map(reports, &Map.put(&1, :message_removed, removed[&1.target_id]))
  end

  @doc "Preuve (instantané du message signalé) contre un motif de consultation, après l'entrée d'audit."
  def evidence(staff_id, report_id, params) do
    reason = trimmed(params["reason"])

    with :ok <- check_reason(reason, 10),
         {:ok, report} <- get(report_id),
         :ok <- if(report.target_type == "message", do: :ok, else: {:error, :no_evidence}),
         :ok <-
           Accounts.audit(
             staff_id,
             "social.report.evidence_viewed",
             "report",
             report.id,
             reason,
             %{
               "message_id" => report.target_id,
               "reported_user_id" => report.message_sender_id
             }
           ) do
      {:ok,
       %{
         report_id: report.id,
         message_id: report.target_id,
         body: report.message_body,
         sender_id: report.message_sender_id,
         sent_at: report.message_sent_at,
         removed: report.message_removed == true,
         attachment: attachment_meta(report)
       }}
    end
  end

  defp attachment_meta(%{message_attachment_id: id}) when is_binary(id) do
    case Repo.get(Attachment, id) do
      %Attachment{} = a ->
        Map.take(Attachment.to_map(a), ~w(id kind content_type filename byte_size available))

      nil ->
        nil
    end
  end

  defp attachment_meta(_report), do: nil

  @doc """
  Contenu de la pièce jointe du message signalé, contre un motif, après l'entrée d'audit
  `social.report.attachment_viewed`.
  """
  def attachment(staff_id, report_id, params) do
    reason = trimmed(params["reason"])

    with :ok <- check_reason(reason, 10),
         {:ok, report} <- get(report_id),
         %Attachment{} = a <-
           report.message_attachment_id && Repo.get(Attachment, report.message_attachment_id),
         {:ok, a, data} <- Attachments.file(a),
         :ok <-
           Accounts.audit(
             staff_id,
             "social.report.attachment_viewed",
             "report",
             report.id,
             reason,
             %{
               "message_id" => report.target_id,
               "attachment_id" => a.id,
               "kind" => a.kind
             }
           ) do
      {:ok, a, data}
    else
      nil -> {:error, :no_attachment}
      error -> error
    end
  end

  @doc """
  Résout un signalement ouvert : `{:ok, report}`, ou `{:error, :not_found | :already_resolved | :staff_target |
  :accounts_unavailable | :audit_unavailable | {:invalid, errors}}`.
  """
  def resolve(staff_id, report_id, params) do
    action = params["action"]
    reason = trimmed(params["reason"])

    with :ok <- validate(action, reason, params),
         {:ok, id} <- cast_id(report_id),
         {:ok, {report, removed}} <-
           Repo.transact(fn -> resolve_locked(id, staff_id, action, reason, params) end) do
      if removed, do: Delivery.message_removed(removed)

      get(report.id)
    end
  end

  defp validate(action, reason, params) do
    cond do
      action not in @actions ->
        {:error, {:invalid, %{action: ["is invalid"]}}}

      action == "restrict" and duration(params) not in 1..720 ->
        {:error, {:invalid, %{duration_hours: ["must be between 1 and 720 hours"]}}}

      true ->
        check_reason(reason, 5)
    end
  end

  defp duration(params) do
    case params["duration_hours"] do
      hours when is_integer(hours) -> hours
      hours when is_binary(hours) -> String.to_integer(hours)
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp resolve_locked(id, staff_id, action, reason, params) do
    with {:ok, report} <- lock_open(id),
         :ok <- applicable(report, action),
         {:ok, outcome} <- apply_action(report, staff_id, action, reason, params),
         :ok <-
           Accounts.audit(
             staff_id,
             "social.report.resolved",
             "report",
             report.id,
             reason,
             Map.merge(%{"action" => action, "target_type" => report.target_type}, outcome.meta)
           ) do
      scope =
        if action == "remove_message",
          do:
            from(r in Report,
              where:
                r.status == "open" and r.target_type == "message" and
                  r.target_id == ^report.target_id
            ),
          else: from(r in Report, where: r.id == ^report.id)

      Repo.update_all(scope,
        set: [
          status: "resolved",
          resolution: action,
          resolution_reason: reason,
          resolved_by: staff_id,
          resolved_at: DateTime.utc_now(),
          sanction_id: outcome.meta["sanction_id"]
        ]
      )

      {:ok, {report, outcome.removed}}
    end
  end

  defp lock_open(id) do
    case Repo.one(from r in Report, where: r.id == ^id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      %Report{status: "open"} = report -> {:ok, report}
      %Report{} -> {:error, :already_resolved}
    end
  end

  defp applicable(%Report{target_type: "user"}, "remove_message"),
    do: {:error, {:invalid, %{action: ["only applies to a reported message"]}}}

  defp applicable(_report, _action), do: :ok

  defp apply_action(_report, _staff_id, "dismiss", _reason, _params),
    do: {:ok, %{meta: %{}, removed: nil}}

  defp apply_action(report, staff_id, "remove_message", _reason, _params) do
    {_, removed} =
      Repo.update_all(
        from(m in Message,
          where: m.id == ^report.target_id and is_nil(m.removed_at),
          select: m
        ),
        set: [removed_at: DateTime.utc_now(), removed_by: staff_id]
      )

    {:ok, %{meta: %{"message_id" => report.target_id}, removed: List.first(removed)}}
  end

  defp apply_action(report, staff_id, action, reason, params) when action in ~w(warn restrict) do
    target = report.message_sender_id || report.target_id

    body =
      if action == "warn",
        do: %{kind: "warning"},
        else: %{kind: "restriction", duration_hours: duration(params)}

    case Client.post(:accounts, "/api/admin/users/:id/sanctions",
           path_params: [id: target],
           as: staff_id,
           json: Map.merge(body, %{reason: reason, ref: "social:report:#{report.id}"})
         ) do
      {:ok, %{"sanction" => %{"id" => sanction_id}}} ->
        {:ok, %{meta: %{"sanction_id" => sanction_id, "user_id" => target}, removed: nil}}

      {:error, {:http, 409, %{"error" => "staff_target"}}} ->
        {:error, :staff_target}

      {:error, {:http, 403, %{"error" => code}}} when code in ["self", "forbidden"] ->
        {:error, :forbidden}

      {:error, {:http, 404, _}} ->
        {:error, {:invalid, %{action: ["the reported member no longer exists"]}}}

      {:error, {:http, 422, %{"errors" => errors}}} ->
        {:error, {:invalid, errors}}

      _ ->
        {:error, :accounts_unavailable}
    end
  end

  @doc "Indicateurs réels : messages des 7 derniers jours, signalements ouverts."
  def stats(now \\ DateTime.utc_now()) do
    week_ago = DateTime.add(now, -7, :day)

    %{
      messages_7d:
        Repo.aggregate(
          from(m in Message, where: m.kind == "text" and m.inserted_at > ^week_ago),
          :count
        ),
      open_reports: Repo.aggregate(from(r in Report, where: r.status == "open"), :count)
    }
  end

  defp check_reason(nil, _min), do: {:error, {:invalid, %{reason: ["can't be blank"]}}}

  defp check_reason(reason, min) do
    cond do
      String.length(reason) < min ->
        {:error, {:invalid, %{reason: ["should be at least #{min} character(s)"]}}}

      String.length(reason) > 1000 or String.contains?(reason, <<0>>) ->
        {:error, {:invalid, %{reason: ["is invalid"]}}}

      true ->
        :ok
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trimmed(_), do: nil

  defp page(value) do
    case Integer.parse(to_string(value || "1")) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp cast_id(id) do
    with :error <- Ecto.UUID.cast(id), do: {:error, :not_found}
  end
end
