defmodule MlAccounts.Audit do
  @moduledoc """
  Journal d'audit des actions du staff, en ajout seul : un déclencheur refuse toute modification.
  `metadata` refuse toute clé qui pourrait porter un secret, un e-mail ou un contenu de message.
  """
  import Ecto.Changeset
  import Ecto.Query
  alias MlAccounts.{AuditEntry, Repo, User}

  @per_page 50
  @export_max 10_000
  @writers ~w(social community multiplayer billing learning studio)
  @forbidden_keys ~w(body content text message message_body details password token secret code email payload)
  @max_metadata_bytes 4_000
  @csv_columns ~w(id inserted_at service actor_id actor_username action target_type target_id reason metadata)

  def export_max, do: @export_max

  @doc "Services autorisés à écrire dans le journal par HTTP."
  def writers, do: @writers

  @doc "Entrée écrite par accounts (action préfixée par `accounts.`), dans la transaction de l'action."
  def record!(actor_id, action, target_type, target_id, reason, metadata \\ %{}) do
    Repo.insert!(%AuditEntry{
      service: "accounts",
      actor_id: actor_id,
      action: "accounts." <> action,
      target_type: target_type,
      target_id: target_id && to_string(target_id),
      reason: reason,
      metadata: metadata
    })
  end

  @doc "Entrée envoyée par le service `service` : `{:ok, entry}` ou changeset invalide."
  def create(service, attrs) when is_map(attrs) do
    %AuditEntry{service: service}
    |> cast(attrs, [:actor_id, :action, :target_type, :target_id, :reason, :metadata])
    |> validate_required([:actor_id, :action])
    |> validate_length(:action, max: 80)
    |> validate_format(:action, ~r/^[a-z_]+(\.[a-z_]+){1,3}$/)
    |> validate_change(:action, fn :action, action ->
      if String.starts_with?(action, service <> "."),
        do: [],
        else: [action: "must start with \"#{service}.\""]
    end)
    |> validate_length(:target_type, max: 40)
    |> validate_length(:target_id, max: 120)
    |> validate_length(:reason, max: 2000)
    |> validate_no_nul([:target_type, :target_id, :reason])
    |> validate_metadata()
    |> Repo.insert()
  end

  def create(_service, _attrs), do: {:error, {:invalid, %{metadata: ["is invalid"]}}}

  defp validate_no_nul(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, cs ->
      validate_change(cs, field, fn _, value ->
        if String.contains?(value, <<0>>), do: [{field, "is invalid"}], else: []
      end)
    end)
  end

  defp validate_metadata(changeset) do
    changeset = put_change(changeset, :metadata, get_field(changeset, :metadata) || %{})
    metadata = get_field(changeset, :metadata)
    encoded = Jason.encode!(metadata)

    cond do
      forbidden_key?(metadata) ->
        add_error(changeset, :metadata, "must not contain secrets, emails or message content")

      byte_size(encoded) > @max_metadata_bytes or String.contains?(encoded, "\\u0000") ->
        add_error(changeset, :metadata, "is invalid")

      true ->
        changeset
    end
  end

  defp forbidden_key?(map) when is_map(map),
    do:
      Enum.any?(map, fn {k, v} ->
        String.downcase(to_string(k)) in @forbidden_keys or forbidden_key?(v)
      end)

  defp forbidden_key?(list) when is_list(list), do: Enum.any?(list, &forbidden_key?/1)
  defp forbidden_key?(_), do: false

  ## Consultation (admin)

  @doc "Page d'entrées, les plus récentes d'abord : `{:ok, page}` ou `{:error, {:invalid, errors}}`."
  def list(params) do
    with {:ok, query} <- filtered(params) do
      page = MlAccounts.Staff.page(params["page"])
      total = Repo.aggregate(query, :count)

      entries =
        Repo.all(
          from e in query,
            order_by: [desc: e.id],
            limit: @per_page,
            offset: ^((page - 1) * @per_page)
        )

      {:ok,
       %{
         entries: with_actors(entries),
         page: page,
         total: total,
         total_pages: max(div(total + @per_page - 1, @per_page), 1)
       }}
    end
  end

  @doc "Exporte en CSV les 10 000 entrées filtrées les plus récentes et audite l'export lui-même."
  def export(%User{} = admin, params) do
    with {:ok, query} <- filtered(params) do
      rows = Repo.all(from e in query, order_by: [desc: e.id], limit: ^(@export_max + 1))
      truncated = length(rows) > @export_max
      rows = Enum.take(rows, @export_max)

      record!(admin.id, "audit.exported", "audit", nil, nil, %{
        "filters" => Map.take(params, ~w(action actor from to)),
        "rows" => length(rows),
        "truncated" => truncated
      })

      {:ok, csv(with_actors(rows)), truncated}
    end
  end

  @doc "Lignes CSV (RFC 4180) ; une cellule commençant par `= + - @`, une tabulation ou un retour chariot est préfixée par `'`."
  def csv(entries) do
    rows =
      for e <- entries do
        [
          e.id,
          DateTime.to_iso8601(e.inserted_at),
          e.service,
          e.actor_id,
          e.actor && e.actor.username,
          e.action,
          e.target_type,
          e.target_id,
          e.reason,
          Jason.encode!(e.metadata)
        ]
      end

    Enum.map([@csv_columns | rows], fn row ->
      [row |> Enum.map(&csv_cell/1) |> Enum.intersperse(","), "\r\n"]
    end)
  end

  @doc false
  def csv_cell(nil), do: ""

  def csv_cell(value) do
    value = to_string(value)

    value =
      if String.starts_with?(value, ["=", "+", "-", "@", "\t", "\r"]),
        do: "'" <> value,
        else: value

    if String.contains?(value, [",", "\"", "\n", "\r"]),
      do: [?", String.replace(value, "\"", "\"\""), ?"],
      else: value
  end

  # Filtres : `action` (préfixe), `actor` (pseudonyme ou UUID), `from` / `to` (dates AAAA-MM-JJ, incluses).
  defp filtered(params) do
    with {:ok, from} <- date(params, "from"),
         {:ok, to} <- date(params, "to") do
      query =
        AuditEntry
        |> filter_action(params["action"])
        |> filter_actor(params["actor"])
        |> filter_from(from)
        |> filter_to(to)

      {:ok, query}
    end
  end

  defp filter_action(query, action) when is_binary(action) and action != "" do
    prefix = action |> String.trim() |> String.slice(0, 80) |> escape_like()
    where(query, [e], like(e.action, ^(prefix <> "%")))
  end

  defp filter_action(query, _), do: query

  defp filter_actor(query, actor) when is_binary(actor) and actor != "" do
    actor = String.trim(actor)

    case Ecto.UUID.cast(actor) do
      {:ok, id} ->
        where(query, [e], e.actor_id == ^id)

      :error ->
        ids = from u in User, where: u.username == ^String.downcase(actor), select: u.id
        where(query, [e], e.actor_id in subquery(ids))
    end
  end

  defp filter_actor(query, _), do: query

  defp filter_from(query, nil), do: query

  defp filter_from(query, date),
    do: where(query, [e], e.inserted_at >= ^DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))

  defp filter_to(query, nil), do: query

  defp filter_to(query, date),
    do:
      where(
        query,
        [e],
        e.inserted_at < ^DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
      )

  defp date(params, key) do
    case params[key] do
      value when value in [nil, ""] ->
        {:ok, nil}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> {:error, {:invalid, %{key => ["is invalid"]}}}
        end

      _ ->
        {:error, {:invalid, %{key => ["is invalid"]}}}
    end
  end

  defp escape_like(value), do: String.replace(value, ["\\", "%", "_"], &"\\#{&1}")

  # Acteur public (pseudonyme, nom affiché) de chaque entrée, en une requête.
  defp with_actors(entries) do
    ids = entries |> Enum.map(& &1.actor_id) |> Enum.uniq()
    actors = MlAccounts.Staff.people(ids)
    Enum.map(entries, &Map.put(&1, :actor, actors[&1.actor_id]))
  end
end
