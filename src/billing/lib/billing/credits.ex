defmodule MlBilling.Credits do
  @moduledoc """
  AI credits spent by the studio: a monthly allocation from the effective plan, with no carry-over.
  Every operation locks the user's account row, and the balance can never become negative.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias MlBilling.{CreditAccount, CreditEntry, Repo}

  @allowances %{"free" => 20, "premium" => 300, "vip" => 1000}
  @page_size 20
  @ref_format ~r/^[a-z]+:[A-Za-z0-9:_\-]{1,120}$/

  @doc "Credits granted per UTC month for a plan."
  def allowance(plan), do: Map.fetch!(@allowances, plan)

  @doc "UTC month of `now`, e.g. `\"2026-11\"`."
  def period(now), do: Calendar.strftime(now, "%Y-%m")

  @doc "Start of the next UTC month: when the remaining credits expire."
  def resets_at(now) do
    first = now |> DateTime.to_date() |> Date.beginning_of_month() |> Date.shift(month: 1)
    DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
  end

  @doc "Account (after the allocation of the month) and a page of its history, newest first."
  def overview(user_id, page \\ 1, now \\ DateTime.utc_now()) do
    {:ok, account} = Repo.transact(fn -> {:ok, lock_account(user_id, now)} end)
    entries = from e in CreditEntry, where: e.user_id == ^user_id
    total = Repo.aggregate(entries, :count)

    %{
      account: account,
      resets_at: resets_at(now),
      page: page,
      total: total,
      total_pages: max(div(total + @page_size - 1, @page_size), 1),
      entries:
        Repo.all(
          from e in entries,
            order_by: [desc: e.seq],
            limit: @page_size,
            offset: ^((page - 1) * @page_size)
        )
    }
  end

  @doc "Holds `amount` credits under `ref`, or returns `{:error, {:insufficient_credits, balance}}`."
  def reserve(user_id, amount, ref, reason \\ nil, now \\ DateTime.utc_now()) do
    run(user_id, now, fn account ->
      case find(user_id, "reservation", ref) do
        %CreditEntry{} = held ->
          {:ok, {reply(held, state(held)), account}}

        nil when account.balance < amount ->
          {:error, {:insufficient_credits, account.balance}}

        nil ->
          account =
            append(account, "reservation", amount, -amount, ref, now,
              reason: reason,
              reserved: account.reserved + amount
            )

          {:ok, {%{ref: ref, status: "held", amount: amount}, account}}
      end
    end)
  end

  @doc "Consumes a held reservation once the generation succeeded."
  def consume(user_id, ref, now \\ DateTime.utc_now()) do
    run(user_id, now, fn account ->
      with {:ok, held} <- reservation(user_id, ref) do
        case state(held) do
          "consumed" ->
            {:ok, {reply(held, "consumed"), account}}

          "released" ->
            {:error, :already_released}

          "held" ->
            account =
              append(account, "consumption", held.amount, 0, ref, now,
                reason: held.reason,
                reserved: account.reserved - held.amount
              )

            {:ok, {reply(held, "consumed"), account}}
        end
      end
    end)
  end

  @doc "Releases a held reservation, giving the credits back exactly once."
  def release(user_id, ref, now \\ DateTime.utc_now()) do
    run(user_id, now, fn account ->
      with {:ok, held} <- reservation(user_id, ref) do
        case state(held) do
          "released" ->
            refunded = find(user_id, "release", ref).delta
            {:ok, {Map.put(reply(held, "released"), :refunded, refunded), account}}

          "consumed" ->
            {:error, :already_consumed}

          "held" ->
            refund = if held.period == account.period, do: held.amount, else: 0

            account =
              append(account, "release", held.amount, refund, ref, now,
                reason: held.reason,
                reserved: account.reserved - held.amount
              )

            {:ok, {Map.put(reply(held, "released"), :refunded, refund), account}}
        end
      end
    end)
  end

  @doc "Grants an exceptional allocation by an admin, applied only if the audit entry is written."
  def adjust(user_id, amount, ref, audit, now \\ DateTime.utc_now()) do
    run(user_id, now, fn account ->
      case find(user_id, "adjustment", ref) do
        %CreditEntry{} = entry ->
          {:ok, {%{ref: ref, status: "duplicate", amount: entry.amount}, account}}

        nil ->
          account =
            append(account, "adjustment", amount, amount, ref, now, reason: "admin_adjustment")

          with :ok <- audit.(account.balance),
               do: {:ok, {%{ref: ref, status: "applied", amount: amount}, account}}
      end
    end)
  end

  @doc "Applies an entitlement change at once to users who already have a credit account."
  def sync_plan(user_id, now \\ DateTime.utc_now()) do
    if Repo.exists?(from a in CreditAccount, where: a.user_id == ^user_id) do
      {:ok, account} = Repo.transact(fn -> {:ok, lock_account(user_id, now)} end)
      notify(account)
    end

    :ok
  end

  @doc "Validates the parameters of an internal call made by the service `caller`."
  def params(params, caller, required) do
    types = %{user_id: Ecto.UUID, amount: :integer, ref: :string, reason: :string}

    {%{}, types}
    |> Changeset.cast(params, Map.keys(types))
    |> Changeset.validate_required(required)
    |> Changeset.validate_number(:amount, greater_than: 0, less_than_or_equal_to: 1000)
    |> Changeset.validate_format(:ref, @ref_format)
    |> Changeset.validate_change(:ref, fn :ref, ref ->
      if String.starts_with?(ref, caller <> ":"),
        do: [],
        else: [ref: "must start with \"#{caller}:\""]
    end)
    |> Changeset.validate_format(:reason, ~r/^[a-z_]{1,40}$/)
    |> Changeset.apply_action(:validate)
  end

  ## Internals

  defp run(user_id, now, fun) do
    case Repo.transact(fn -> fun.(lock_account(user_id, now)) end) do
      {:ok, {reply, account}} ->
        notify(account)
        {:ok, Map.merge(reply, %{balance: account.balance, reserved: account.reserved})}

      {:error, _} = error ->
        error
    end
  end

  # The account row is created if missing (ON CONFLICT DO NOTHING, so that concurrent first
  # operations are serialized too), locked, rolled over to the current month and topped up.
  defp lock_account(user_id, now) do
    stamp = DateTime.truncate(now, :second)

    Repo.insert_all(CreditAccount, [%{user_id: user_id, inserted_at: stamp, updated_at: stamp}],
      on_conflict: :nothing,
      conflict_target: :user_id
    )

    account = Repo.one!(from a in CreditAccount, where: a.user_id == ^user_id, lock: "FOR UPDATE")
    plan = MlBilling.entitlements(user_id, now).plan
    account |> roll_over(plan, now) |> top_up(plan, now)
  end

  defp roll_over(account, plan, now) do
    current = period(now)

    if account.period == current do
      account
    else
      account =
        if account.period && account.balance > 0,
          do:
            append(account, "expiration", account.balance, -account.balance, account.period, now),
          else: account

      granted = allowance(plan)

      append(account, "allocation", granted, granted, current, now,
        period: current,
        plan: plan,
        allocation: granted
      )
    end
  end

  defp top_up(account, plan, now) do
    case allowance(plan) - account.allocation do
      extra when extra > 0 ->
        append(account, "top_up", extra, extra, "#{account.period}:#{plan}", now,
          plan: plan,
          allocation: account.allocation + extra
        )

      _ ->
        account
    end
  end

  # Appends a ledger line and applies its delta (and the other `opts` changes) to the locked account.
  defp append(account, kind, amount, delta, ref, now, opts \\ []) do
    {reason, changes} = Keyword.pop(opts, :reason)
    balance = account.balance + delta

    Repo.insert!(%CreditEntry{
      user_id: account.user_id,
      kind: kind,
      amount: amount,
      delta: delta,
      balance_after: balance,
      ref: ref,
      reason: reason,
      period: Keyword.get(changes, :period, account.period),
      inserted_at: DateTime.add(now, 0, :microsecond)
    })

    account |> Changeset.change([balance: balance] ++ changes) |> Repo.update!()
  end

  defp find(user_id, kind, ref),
    do: Repo.get_by(CreditEntry, user_id: user_id, kind: kind, ref: ref)

  defp reservation(user_id, ref) do
    case find(user_id, "reservation", ref) do
      nil -> {:error, :not_found}
      held -> {:ok, held}
    end
  end

  defp state(%CreditEntry{user_id: user_id, ref: ref}) do
    ends =
      Repo.all(
        from e in CreditEntry,
          where: e.user_id == ^user_id and e.ref == ^ref and e.kind in ["consumption", "release"],
          select: e.kind
      )

    cond do
      "consumption" in ends -> "consumed"
      "release" in ends -> "released"
      true -> "held"
    end
  end

  defp reply(held, status), do: %{ref: held.ref, status: status, amount: held.amount}

  defp notify(account) do
    MlShared.Events.broadcast(
      MlShared.Events.user(account.user_id),
      {:credits_changed, account.user_id, account.balance}
    )
  end
end
