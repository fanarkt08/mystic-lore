defmodule MlAccounts.Sanctions do
  @moduledoc """
  Sanctions posées par le staff et appels des membres, toujours auditées dans la même transaction.
  Un appel est tranché par un membre du staff autre que l'auteur de la sanction.
  """
  import Ecto.Changeset
  import Ecto.Query
  require Logger
  alias MlAccounts.{Audit, Mailer, Repo, Sanction, SanctionAppeal, Staff, User, UserEmail}
  alias MlShared.Events

  @max_hours 720
  @ref_format ~r/^[a-z]+:[A-Za-z0-9:_\-]{1,120}$/
  @per_page 20

  @doc "Chaîne sans espaces de bord, ou nil si vide / pas une chaîne."
  def trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  def trimmed(_), do: nil

  @doc "Fin de la restriction en cours d'un membre, ou nil."
  def restricted_until(user, now \\ DateTime.utc_now())

  def restricted_until(%User{restricted_until: %DateTime{} = until}, now),
    do: if(DateTime.after?(until, now), do: until)

  def restricted_until(_user, _now), do: nil

  ## Staff

  @doc """
  Pose une sanction : `{:ok, sanction, :created | :replayed}` (`:replayed` si la même `ref` existe déjà),
  ou `{:error, :not_found | :self | :staff_target | :conflict | {:invalid, errors}}`.
  """
  def issue(%User{} = staff, target_id, params) do
    with {:ok, attrs} <- issue_params(params),
         %User{} = target <- Staff.get_member(target_id) || {:error, :not_found},
         :ok <- sanctionable(staff, target) do
      case attrs[:ref] && Repo.get_by(Sanction, ref: attrs[:ref]) do
        %Sanction{user_id: user_id} = existing when user_id == target.id ->
          {:ok, existing, :replayed}

        %Sanction{} ->
          {:error, :conflict}

        nil ->
          create(staff, target, attrs)
      end
    end
  end

  defp issue_params(params) do
    types = %{kind: :string, reason: :string, duration_hours: :integer, ref: :string}

    {%{}, types}
    |> cast(params, Map.keys(types))
    |> update_change(:reason, &trimmed/1)
    |> validate_required([:kind, :reason])
    |> validate_inclusion(:kind, ~w(warning restriction))
    |> validate_text(:reason, 5, 1000)
    |> validate_format(:ref, @ref_format)
    |> then(fn cs ->
      if get_field(cs, :kind) == "restriction",
        do:
          cs
          |> validate_required([:duration_hours])
          |> validate_number(:duration_hours,
            greater_than_or_equal_to: 1,
            less_than_or_equal_to: @max_hours
          ),
        else: delete_change(cs, :duration_hours)
    end)
    |> apply_action(:validate)
  end

  defp sanctionable(%User{id: id}, %User{id: id}), do: {:error, :self}
  defp sanctionable(_staff, %User{role: "user"}), do: :ok
  defp sanctionable(_staff, _target), do: {:error, :staff_target}

  defp create(staff, target, attrs) do
    now = DateTime.utc_now(:second)
    ends_at = attrs[:duration_hours] && DateTime.add(now, attrs.duration_hours * 3600)

    Repo.transact(fn ->
      lock_user!(target.id)

      changeset =
        %Sanction{
          user_id: target.id,
          kind: attrs.kind,
          reason: attrs.reason,
          issued_by: staff.id,
          ends_at: ends_at,
          ref: attrs[:ref]
        }
        |> change()
        |> unique_constraint(:ref)

      with {:ok, sanction} <- Repo.insert(changeset) do
        refresh_restriction!(target.id)

        Audit.record!(staff.id, "sanction.issued", "user", target.id, attrs.reason, %{
          "sanction_id" => sanction.id,
          "kind" => sanction.kind,
          "ends_at" => ends_at,
          "ref" => sanction.ref
        })

        {:ok, sanction}
      end
    end)
    |> case do
      {:ok, sanction} ->
        notify(target, UserEmail.sanction_issued(target, sanction))

        MlAccounts.Notify.account(
          target.id,
          "sanction_issued",
          %{sanction_id: sanction.id, sanction_kind: sanction.kind, ends_at: sanction.ends_at},
          "sanction:#{sanction.id}:issued"
        )

        {:ok, sanction, :created}

      # même `ref` posée en concurrence : la première l'emporte, l'appel est un rejeu
      {:error, %Ecto.Changeset{}} = error ->
        case attrs[:ref] && Repo.get_by(Sanction, ref: attrs.ref) do
          %Sanction{user_id: user_id} = existing when user_id == target.id ->
            {:ok, existing, :replayed}

          _ ->
            error
        end
    end
  end

  @doc "Lève une sanction active (motif obligatoire)."
  def lift(%User{} = staff, sanction_id, params) do
    reason = trimmed(params["reason"])

    with :ok <- check_text(:reason, reason, 5, 1000),
         {:ok, id} <- cast_id(sanction_id),
         {:ok, sanction} <-
           Repo.transact(fn ->
             with %Sanction{} = sanction <- Repo.get(Sanction, id) || {:error, :not_found},
                  _user = lock_user!(sanction.user_id),
                  sanction = Repo.reload!(sanction),
                  :ok <- active(sanction) do
               sanction = lift!(sanction, staff, reason)

               Audit.record!(staff.id, "sanction.lifted", "user", sanction.user_id, reason, %{
                 "sanction_id" => sanction.id,
                 "kind" => sanction.kind
               })

               {:ok, sanction}
             end
           end) do
      user = Repo.get!(User, sanction.user_id)
      notify(user, UserEmail.sanction_lifted(user, sanction))

      MlAccounts.Notify.account(
        user.id,
        "sanction_lifted",
        %{sanction_id: sanction.id, sanction_kind: sanction.kind},
        "sanction:#{sanction.id}:lifted"
      )

      {:ok, sanction}
    end
  end

  defp active(sanction),
    do: if(Sanction.status(sanction) == "active", do: :ok, else: {:error, :not_active})

  defp lift!(sanction, staff, reason) do
    sanction =
      sanction
      |> change(lifted_at: DateTime.utc_now(:second), lifted_by: staff.id, lift_reason: reason)
      |> Repo.update!()

    refresh_restriction!(sanction.user_id)
    sanction
  end

  @doc "Appels d'une file (`open` : plus anciens d'abord ; `decided` : plus récents d'abord), 20 par page."
  def list_appeals(params) do
    status = if params["status"] == "decided", do: "decided", else: "open"
    page = Staff.page(params["page"])

    query =
      if status == "open",
        do: from(a in SanctionAppeal, where: a.status == "open", order_by: [asc: a.inserted_at]),
        else: from(a in SanctionAppeal, where: a.status != "open", order_by: [desc: a.decided_at])

    total = Repo.aggregate(exclude(query, :order_by), :count)

    entries =
      Repo.all(
        from a in query,
          limit: @per_page,
          offset: ^((page - 1) * @per_page),
          preload: [:sanction, :user]
      )

    %{
      status: status,
      entries: entries,
      page: page,
      total: total,
      total_pages: max(div(total + @per_page - 1, @per_page), 1)
    }
  end

  @doc "Tranche un appel ouvert ; l'accepter lève la sanction."
  def decide(%User{} = staff, appeal_id, params) do
    decision = params["decision"]
    reason = trimmed(params["reason"])

    with :ok <-
           if(decision in ~w(accept reject),
             do: :ok,
             else: {:error, {:invalid, %{decision: ["is invalid"]}}}
           ),
         :ok <- check_text(:reason, reason, 5, 1000),
         {:ok, id} <- cast_id(appeal_id),
         {:ok, appeal} <-
           Repo.transact(fn -> decide_locked(staff, id, decision, reason) end) do
      user = Repo.get!(User, appeal.user_id)
      notify(user, UserEmail.appeal_decided(user, appeal))

      MlAccounts.Notify.account(
        user.id,
        "appeal_decided",
        %{appeal_id: appeal.id, outcome: appeal.status},
        "appeal:#{appeal.id}:decided"
      )

      {:ok, appeal}
    end
  end

  defp decide_locked(staff, id, decision, reason) do
    with %SanctionAppeal{} = appeal <-
           Repo.one(from a in SanctionAppeal, where: a.id == ^id, lock: "FOR UPDATE") ||
             {:error, :not_found},
         :ok <- if(appeal.status == "open", do: :ok, else: {:error, :already_decided}),
         _user = lock_user!(appeal.user_id),
         sanction = Repo.get!(Sanction, appeal.sanction_id),
         :ok <- if(sanction.issued_by == staff.id, do: {:error, :same_staff}, else: :ok) do
      status = if decision == "accept", do: "accepted", else: "rejected"
      lift? = status == "accepted" and Sanction.status(sanction) == "active"

      sanction =
        if lift?, do: lift!(sanction, staff, "Appeal accepted: " <> reason), else: sanction

      appeal =
        appeal
        |> change(
          status: status,
          decided_by: staff.id,
          decision_reason: reason,
          decided_at: DateTime.utc_now(:second)
        )
        |> Repo.update!()

      Audit.record!(staff.id, "appeal.#{status}", "user", appeal.user_id, reason, %{
        "appeal_id" => appeal.id,
        "sanction_id" => sanction.id,
        "sanction_lifted" => lift?
      })

      {:ok, %{appeal | sanction: sanction}}
    end
  end

  ## Membre

  @doc "Sanctions d'un membre (plus récentes d'abord) avec leurs appels (plus récents d'abord)."
  def for_user(user_id),
    do:
      Repo.all(
        from s in Sanction,
          where: s.user_id == ^user_id,
          order_by: [desc: s.inserted_at],
          preload: :appeals
      )

  @doc "Appel du membre sur sa propre sanction active."
  def appeal(%User{} = member, sanction_id, params) do
    body = trimmed(params["body"])

    with :ok <- check_text(:body, body, 10, 2000),
         {:ok, id} <- cast_id(sanction_id),
         %Sanction{} = sanction <-
           Repo.get_by(Sanction, id: id, user_id: member.id) || {:error, :not_found},
         :ok <-
           if(Sanction.status(sanction) == "active", do: :ok, else: {:error, :not_appealable}) do
      %SanctionAppeal{sanction_id: sanction.id, user_id: member.id, body: body}
      |> change()
      |> unique_constraint(:sanction_id, name: :sanction_appeals_one_open_index)
      |> Repo.insert()
      |> case do
        {:ok, appeal} ->
          broadcast(member.id)
          {:ok, appeal}

        {:error, %Ecto.Changeset{}} ->
          {:error, :appeal_open}
      end
    end
  end

  @doc "Une sanction peut faire l'objet d'un appel : active et sans appel ouvert."
  def appealable?(%Sanction{appeals: appeals} = sanction) when is_list(appeals),
    do: Sanction.status(sanction) == "active" and not Enum.any?(appeals, &(&1.status == "open"))

  ## Interne

  defp lock_user!(user_id),
    do: Repo.one!(from u in User, where: u.id == ^user_id, lock: "FOR UPDATE")

  defp refresh_restriction!(user_id) do
    now = DateTime.utc_now(:second)

    until =
      Repo.one(
        from s in Sanction,
          where: s.user_id == ^user_id and s.kind == "restriction" and is_nil(s.lifted_at),
          where: s.ends_at > ^now,
          select: max(s.ends_at)
      )

    Repo.update_all(from(u in User, where: u.id == ^user_id), set: [restricted_until: until])
  end

  defp notify(user, email) do
    broadcast(user.id)

    with {:error, reason} <- Mailer.deliver(email) do
      Logger.error("#{email.subject}: email not delivered to user #{user.id}: #{inspect(reason)}")
    end

    :ok
  end

  defp broadcast(user_id) do
    Events.broadcast(Events.user(user_id), {:sanction_changed, user_id})
    Events.broadcast("members", {:sanction_changed, user_id})
  end

  defp cast_id(id) do
    with :error <- Ecto.UUID.cast(id), do: {:error, :not_found}
  end

  defp validate_text(changeset, field, min, max) do
    changeset
    |> validate_length(field, min: min, max: max)
    |> validate_change(field, fn _, value ->
      if String.contains?(value, <<0>>), do: [{field, "is invalid"}], else: []
    end)
  end

  @doc false
  def check_text(field, value, min, max) do
    cond do
      is_nil(value) ->
        {:error, {:invalid, %{field => ["can't be blank"]}}}

      String.contains?(value, <<0>>) ->
        {:error, {:invalid, %{field => ["is invalid"]}}}

      String.length(value) < min ->
        {:error, {:invalid, %{field => ["should be at least #{min} character(s)"]}}}

      String.length(value) > max ->
        {:error, {:invalid, %{field => ["should be at most #{max} character(s)"]}}}

      true ->
        :ok
    end
  end
end
