defmodule MlAccounts.Support do
  @moduledoc """
  Demandes de support du formulaire de contact, avec leurs limites de débit et leur traitement par le staff.
  L'accusé de réception ne reprend jamais le texte soumis, sinon le formulaire servirait de relais de spam.
  """
  import Ecto.Query
  require Logger

  alias MlAccounts.{
    Audit,
    Mailer,
    Repo,
    Staff,
    SupportEmail,
    SupportReply,
    SupportRequest,
    Throttle,
    User
  }

  @per_page 20
  @message_length {10, 4000}
  @reply_length {2, 5000}
  @note_max 4000
  @mine_max 50
  @inactive_days 365
  @email_format ~r/^[^@,;\s]+@[^@,;\s]+$/
  # caractères de contrôle (sauf tabulation, saut de ligne, retour chariot) et contrôles bidirectionnels
  @forbidden ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  @reference_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  def topics, do: SupportRequest.topics()

  defp limit(scope) do
    defaults = [account: {5, 24 * 60}, address: {3, 24 * 60}]

    Keyword.get(Application.get_env(:accounts, :support_limits, defaults), scope) ||
      defaults[scope]
  end

  def retention_days, do: Application.get_env(:accounts, :support_retention_days, 180)

  ## Envoi

  @doc """
  Nouvelle demande d'un membre (`%User{}`) ou d'un visiteur (`nil`) : `{:ok, request, :sent | :failed}` selon
  la remise de l'accusé de réception, `{:error, {:invalid, erreurs}}` ou `{:error, :rate_limited}`.
  """
  def create(requester, params) when is_map(params) do
    with {:ok, attrs} <- validate(requester, params) do
      address = if requester, do: requester.email, else: attrs.email

      Repo.transact(fn ->
        # membre : limite par compte ; visiteur : limite par adresse cible (celle qu'il a saisie)
        with :ok <- reserve(requester, address) do
          {:ok, insert_request(requester, attrs)}
        end
      end)
      |> case do
        {:ok, request} -> {:ok, request, acknowledge(request, address)}
        {:error, :locked} -> {:error, :rate_limited}
        error -> error
      end
    end
  end

  def create(_requester, _params), do: {:error, {:invalid, %{message: ["can't be blank"]}}}

  defp validate(requester, params) do
    message = text(params["message"])
    email = if requester, do: nil, else: email(params["email"])

    errors =
      %{}
      |> put_error(:topic, if(params["topic"] in topics(), do: nil, else: "is invalid"))
      |> put_error(:message, text_error(message, @message_length))
      |> put_error(:email, if(requester, do: nil, else: email_error(email)))

    if errors == %{} do
      {:ok,
       %{
         topic: params["topic"],
         message: message,
         email: email,
         locale: if(params["locale"] in ~w(en fr), do: params["locale"], else: "en")
       }}
    else
      {:error, {:invalid, errors}}
    end
  end

  defp put_error(errors, _field, nil), do: errors
  defp put_error(errors, field, message), do: Map.put(errors, field, [message])

  # texte libre : retours à la ligne normalisés, espaces de bord retirés ; une valeur invalide reste détectable
  defp text(value) when is_binary(value) do
    if String.valid?(value),
      do: value |> String.replace("\r\n", "\n") |> String.trim(),
      else: :invalid
  end

  defp text(_value), do: nil

  defp text_error(nil, _bounds), do: "can't be blank"
  defp text_error("", _bounds), do: "can't be blank"
  defp text_error(:invalid, _bounds), do: "is invalid"

  defp text_error(value, {min, max}) do
    cond do
      Regex.match?(@forbidden, value) -> "must not contain control characters"
      String.length(value) < min -> "should be at least #{min} character(s)"
      String.length(value) > max -> "should be at most #{max} character(s)"
      true -> nil
    end
  end

  defp email(value) when is_binary(value) do
    if String.valid?(value), do: User.normalize(value), else: :invalid
  end

  defp email(_value), do: nil

  defp email_error(nil), do: "can't be blank"
  defp email_error(""), do: "can't be blank"
  defp email_error(:invalid), do: "is invalid"

  defp email_error(email) do
    cond do
      Regex.match?(@forbidden, email) -> "is invalid"
      String.length(email) > 160 -> "should be at most 160 character(s)"
      not Regex.match?(@email_format, email) -> "must have the @ sign and no spaces"
      String.ends_with?(email, "@deleted.invalid") -> "is invalid"
      true -> nil
    end
  end

  defp reserve(nil, address) do
    {count, minutes} = limit(:address)
    Throttle.reserve("support_address:" <> address_key(address), count, minutes)
  end

  defp reserve(%User{id: user_id}, _address) do
    {count, minutes} = limit(:account)
    Throttle.reserve("support_account:" <> user_id, count, minutes)
  end

  # HMAC de l'adresse normalisée : la table des limites ne contient jamais l'adresse elle-même
  defp address_key(address) do
    :hmac
    |> :crypto.mac(:sha256, MlShared.InternalToken.secret(), "ml-accounts:support:" <> address)
    |> Base.encode16(case: :lower)
  end

  defp insert_request(requester, attrs) do
    Repo.insert!(%SupportRequest{
      reference: reference(),
      user_id: requester && requester.id,
      email: attrs.email,
      topic: attrs.topic,
      message: attrs.message,
      locale: attrs.locale
    })
  end

  # « REQ-7K3D9-QXA2M » : 10 caractères base32 de Crockford (50 bits), index unique
  defp reference do
    chars =
      for <<byte <- :crypto.strong_rand_bytes(10)>>,
        do: Enum.at(@reference_alphabet, rem(byte, 32))

    {a, b} = Enum.split(chars, 5)
    "REQ-#{a}-#{b}"
  end

  defp acknowledge(request, address) do
    request |> SupportEmail.acknowledgement(address) |> deliver(request)
  end

  defp deliver(email, request) do
    case Mailer.deliver(email) do
      {:ok, _} ->
        :sent

      {:error, _reason} ->
        # jamais l'adresse ni le contenu dans le journal (la raison d'un fournisseur peut citer le destinataire)
        Logger.error("support e-mail not delivered for request #{request.id}")
        :failed
    end
  end

  ## Membre

  @doc "Les demandes du membre (les plus récentes d'abord, 50 au plus) avec les réponses du staff."
  def mine(%User{id: user_id}) do
    Repo.all(
      from r in SupportRequest,
        where: r.user_id == ^user_id,
        order_by: [desc: r.inserted_at],
        limit: @mine_max,
        preload: :replies
    )
  end

  @doc "Section `support_requests` de l'export de données du membre (toutes ses demandes, note interne comprise)."
  def export(%User{id: user_id}) do
    Repo.all(
      from r in SupportRequest,
        where: r.user_id == ^user_id,
        order_by: [asc: r.inserted_at],
        preload: :replies
    )
    |> Enum.map(fn r ->
      %{
        "reference" => r.reference,
        "topic" => r.topic,
        "message" => r.message,
        "status" => r.status,
        "locale" => r.locale,
        "internal_note" => r.internal_note,
        "inserted_at" => r.inserted_at,
        "answered_at" => r.answered_at,
        "closed_at" => r.closed_at,
        "replies" => Enum.map(r.replies, &%{"body" => &1.body, "inserted_at" => &1.inserted_at})
      }
    end)
  end

  ## Staff

  @doc "Liste les demandes pour le staff, 20 par page ; la consultation des adresses par un admin est auditée."
  def list(%User{} = viewer, params) do
    page = Staff.page(params["page"])
    status = if params["status"] in SupportRequest.statuses(), do: params["status"]
    q = params["q"] |> to_string() |> String.trim() |> String.slice(0, 100)

    query =
      from(r in SupportRequest)
      |> by(:status, status)
      |> by(:topic, if(params["topic"] in topics(), do: params["topic"]))
      |> search(q, Staff.admin?(viewer))

    total = Repo.aggregate(query, :count)
    order = if status == "open", do: [asc: :inserted_at], else: [desc: :inserted_at]

    entries =
      Repo.all(
        from r in query,
          order_by: ^order,
          limit: @per_page,
          offset: ^((page - 1) * @per_page)
      )

    if Staff.admin?(viewer) do
      Audit.record!(viewer.id, "support.listed", "support_request", nil, nil, %{
        "status" => status,
        "q" => q,
        "page" => page,
        "count" => length(entries)
      })
    end

    %{
      entries: entries,
      replies: reply_counts(entries),
      users: users(entries),
      page: page,
      total: total,
      total_pages: max(div(total + @per_page - 1, @per_page), 1)
    }
  end

  defp by(query, _field, nil), do: query
  defp by(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp search(query, "", _admin?), do: query

  defp search(query, q, admin?) do
    prefix = String.replace(q, ["\\", "%", "_"], &"\\#{&1}") <> "%"

    if admin? do
      from r in query,
        left_join: u in User,
        on: u.id == r.user_id,
        where: ilike(r.reference, ^prefix) or ilike(r.email, ^prefix) or ilike(u.email, ^prefix)
    else
      where(query, [r], ilike(r.reference, ^prefix))
    end
  end

  defp reply_counts([]), do: %{}

  defp reply_counts(requests) do
    ids = Enum.map(requests, & &1.id)

    Repo.all(
      from p in SupportReply,
        where: p.request_id in ^ids,
        group_by: p.request_id,
        select: {p.request_id, count(p.id)}
    )
    |> Map.new()
  end

  @doc "`%{user_id => %User{}}` des membres auteurs des demandes."
  def users(requests) do
    ids = requests |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Repo.all(from u in User, where: u.id in ^ids) |> Map.new(&{&1.id, &1})
  end

  @doc "Une demande et ses réponses ; la consultation est auditée (`accounts.support.viewed`)."
  def detail(%User{} = viewer, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %SupportRequest{} = request <- Repo.get(SupportRequest, id) do
      Audit.record!(viewer.id, "support.viewed", "support_request", request.id, nil, %{
        "topic" => request.topic
      })

      {:ok, Repo.preload(request, :replies)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Envoie la réponse du staff par e-mail, sans recopier la demande, et passe celle-ci à `answered`."
  def reply(%User{} = staff, id, params) when is_map(params) do
    body = text(params["body"])

    with {:ok, id} <- cast(id),
         :ok <- check_reply(body),
         {:ok, {request, reply}} <- record_reply(staff, id, body) do
      status = request |> SupportEmail.reply(reply, address(request)) |> deliver(request)
      reply = reply |> Ecto.Changeset.change(email_status: to_string(status)) |> Repo.update!()

      if request.user_id do
        MlAccounts.Notify.account(
          request.user_id,
          "support_replied",
          %{request_id: request.id},
          "support_reply:" <> reply.id
        )
      end

      {:ok, Repo.preload(request, :replies, force: true), reply}
    end
  end

  def reply(_staff, _id, _params), do: {:error, {:invalid, %{body: ["can't be blank"]}}}

  defp check_reply(body) do
    case text_error(body, @reply_length) do
      nil -> :ok
      message -> {:error, {:invalid, %{body: [message]}}}
    end
  end

  defp record_reply(staff, id, body) do
    Repo.transact(fn ->
      with %SupportRequest{} = request <- locked(id) || {:error, :not_found},
           :ok <- if(request.status == "closed", do: {:error, :closed}, else: :ok) do
        reply =
          Repo.insert!(%SupportReply{
            request_id: request.id,
            author_id: staff.id,
            body: body,
            email_status: "pending"
          })

        request =
          request
          |> Ecto.Changeset.change(status: "answered", answered_at: DateTime.utc_now(:second))
          |> Repo.update!()

        Audit.record!(staff.id, "support.replied", "support_request", request.id, nil, %{
          "reply_id" => reply.id,
          "length" => String.length(body)
        })

        {:ok, {request, reply}}
      end
    end)
  end

  # adresse du demandeur au moment de répondre : celle du visiteur, ou celle (actuelle) du compte du membre
  defp address(%SupportRequest{email: email}) when is_binary(email), do: email

  defp address(%SupportRequest{user_id: user_id}),
    do: Repo.one!(from u in User, where: u.id == ^user_id, select: u.email)

  @doc "Change le statut et la note interne d'une demande, en auditant chaque changement."
  def update(%User{} = staff, id, params) when is_map(params) do
    with {:ok, id} <- cast(id),
         {:ok, changes} <- update_changes(params) do
      Repo.transact(fn ->
        with %SupportRequest{} = request <- locked(id) || {:error, :not_found} do
          {:ok, apply_changes(staff, request, changes)}
        end
      end)
      |> case do
        {:ok, request} -> {:ok, Repo.preload(request, :replies)}
        error -> error
      end
    end
  end

  def update(_staff, _id, _params), do: {:error, {:invalid, %{status: ["is invalid"]}}}

  defp update_changes(params) do
    status =
      case Map.fetch(params, "status") do
        {:ok, status} when is_binary(status) ->
          if status in SupportRequest.statuses(), do: {:ok, status}, else: :invalid

        {:ok, _} ->
          :invalid

        :error ->
          :none
      end

    note =
      case Map.fetch(params, "internal_note") do
        {:ok, nil} -> {:ok, nil}
        {:ok, value} when is_binary(value) -> note(text(value))
        {:ok, _} -> :invalid
        :error -> :none
      end

    errors =
      %{}
      |> put_error(:status, if(status == :invalid, do: "is invalid"))
      |> put_error(:internal_note, note_error(note))

    if errors == %{},
      do: {:ok, %{status: status, note: note}},
      else: {:error, {:invalid, errors}}
  end

  defp note(""), do: {:ok, nil}
  defp note(:invalid), do: {:error, "is invalid"}

  defp note(value) do
    cond do
      Regex.match?(@forbidden, value) -> {:error, "must not contain control characters"}
      String.length(value) > @note_max -> {:error, "should be at most #{@note_max} character(s)"}
      true -> {:ok, value}
    end
  end

  defp note_error({:error, message}), do: message
  defp note_error(:invalid), do: "is invalid"
  defp note_error(_), do: nil

  defp apply_changes(staff, request, %{status: status, note: note}) do
    request =
      case status do
        {:ok, new} when new != request.status ->
          updated =
            request
            |> Ecto.Changeset.change(
              status: new,
              closed_at: if(new == "closed", do: DateTime.utc_now(:second))
            )
            |> Repo.update!()

          Audit.record!(staff.id, "support.status_changed", "support_request", request.id, nil, %{
            "from" => request.status,
            "to" => new
          })

          updated

        _ ->
          request
      end

    case note do
      {:ok, value} when value != request.internal_note ->
        updated = request |> Ecto.Changeset.change(internal_note: value) |> Repo.update!()

        Audit.record!(staff.id, "support.note_updated", "support_request", request.id, nil, %{
          "length" => if(value, do: String.length(value), else: 0)
        })

        updated

      _ ->
        request
    end
  end

  @doc "Efface tout de suite une demande et ses réponses (admin seulement)."
  def delete(%User{} = admin, id) do
    with {:ok, id} <- cast(id) do
      Repo.transact(fn ->
        with %SupportRequest{} = request <- locked(id) || {:error, :not_found} do
          Audit.record!(admin.id, "support.deleted", "support_request", request.id, nil, %{
            "topic" => request.topic,
            "reference" => request.reference
          })

          Repo.delete!(request)
          {:ok, request}
        end
      end)
    end
  end

  defp locked(id),
    do: Repo.one(from r in SupportRequest, where: r.id == ^id, lock: "FOR UPDATE")

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  ## Rétention

  @doc "Supprime les demandes closes ou inactives trop anciennes et renvoie leur nombre."
  def purge(now \\ DateTime.utc_now()) do
    closed_before = DateTime.add(now, -retention_days(), :day)
    idle_before = DateTime.add(now, -@inactive_days, :day)

    {count, _} =
      Repo.delete_all(
        from r in SupportRequest,
          where:
            (r.status == "closed" and r.closed_at <= ^closed_before) or
              r.updated_at <= ^idle_before
      )

    Repo.delete_all(
      from t in Throttle,
        where: like(t.key, "support_%") and t.inserted_at <= ^DateTime.add(now, -1, :day)
    )

    count
  end
end
