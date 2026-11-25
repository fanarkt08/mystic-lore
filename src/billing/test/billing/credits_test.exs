defmodule MlBilling.CreditsTest do
  use MlBilling.DataCase, async: true
  alias MlBilling.{CreditAccount, CreditEntry, Credits, Subscription}

  @nov ~U[2026-11-15 12:00:00Z]
  @dec ~U[2026-12-01 00:00:05Z]

  defp subscribe(user_id, plan, attrs \\ []) do
    Repo.insert!(
      struct(
        %Subscription{
          user_id: user_id,
          plan: plan,
          status: "active",
          provider: "local",
          current_period_end: ~U[2027-06-01 00:00:00Z]
        },
        attrs
      ),
      on_conflict: {:replace, [:plan, :status, :past_due_since]},
      conflict_target: :user_id
    )
  end

  defp kinds(user_id),
    do:
      Repo.all(
        from e in CreditEntry,
          where: e.user_id == ^user_id,
          order_by: e.seq,
          select: {e.kind, e.delta}
      )

  defp ref, do: "studio:gen:#{uuid()}"

  test "the first operation allocates the EFFECTIVE plan's credits of the month" do
    {free, premium, vip, grace} = {uuid(), uuid(), uuid(), uuid()}
    subscribe(premium, "premium")
    subscribe(vip, "vip")
    # past_due for one day: still premium during the 3-day grace period
    subscribe(grace, "premium",
      status: "past_due",
      past_due_since: DateTime.add(@nov, -1, :day)
    )

    for {user_id, credits} <- [{free, 20}, {premium, 300}, {vip, 1000}, {grace, 300}] do
      %{account: account} = Credits.overview(user_id, 1, @nov)
      assert %CreditAccount{period: "2026-11", allocation: ^credits, balance: ^credits} = account
      assert kinds(user_id) == [{"allocation", credits}]
    end

    # idempotent: reading again allocates nothing more
    assert %{account: %{balance: 20}, total: 1} = Credits.overview(free, 1, @nov)
  end

  test "reserve → consume, and release refunds exactly once; replays are idempotent" do
    user_id = uuid()
    {r1, r2} = {ref(), ref()}

    assert {:ok, %{status: "held", amount: 5, balance: 15, reserved: 5}} =
             Credits.reserve(user_id, 5, r1, "lesson_draft", @nov)

    # same ref again: same reservation, nothing more is held
    assert {:ok, %{status: "held", balance: 15, reserved: 5}} =
             Credits.reserve(user_id, 5, r1, "lesson_draft", @nov)

    assert {:ok, %{status: "consumed", balance: 15, reserved: 0}} =
             Credits.consume(user_id, r1, @nov)

    assert {:ok, %{status: "consumed"}} = Credits.consume(user_id, r1, @nov)
    assert {:error, :already_consumed} = Credits.release(user_id, r1, @nov)

    assert {:ok, %{balance: 13}} = Credits.reserve(user_id, 2, r2, "outline", @nov)

    assert {:ok, %{status: "released", refunded: 2, balance: 15}} =
             Credits.release(user_id, r2, @nov)

    assert {:ok, %{status: "released", refunded: 2, balance: 15}} =
             Credits.release(user_id, r2, @nov)

    assert {:error, :already_released} = Credits.consume(user_id, r2, @nov)
    assert {:error, :not_found} = Credits.consume(user_id, ref(), @nov)

    assert kinds(user_id) == [
             {"allocation", 20},
             {"reservation", -5},
             {"consumption", 0},
             {"reservation", -2},
             {"release", 2}
           ]

    # the ledger explains the balance
    assert Repo.one(from e in CreditEntry, where: e.user_id == ^user_id, select: sum(e.delta)) ==
             15
  end

  test "never a negative balance: insufficient credits, database constraint, immutable ledger" do
    user_id = uuid()

    assert {:error, {:insufficient_credits, 20}} = Credits.reserve(user_id, 21, ref(), nil, @nov)
    assert {:ok, %{balance: 0}} = Credits.reserve(user_id, 20, ref(), nil, @nov)
    assert {:error, {:insufficient_credits, 0}} = Credits.reserve(user_id, 1, ref(), nil, @nov)

    assert_raise Postgrex.Error, ~r/credit_balance_non_negative/, fn ->
      Repo.update_all(from(a in CreditAccount, where: a.user_id == ^user_id), set: [balance: -1])
    end
  end

  test "ledger lines can't be modified" do
    user_id = uuid()
    Credits.overview(user_id, 1, @nov)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update_all(from(e in CreditEntry, where: e.user_id == ^user_id), set: [amount: 999])
    end
  end

  test "UTC month change: the rest expires, the new month is allocated, no carry-over" do
    user_id = uuid()
    {spent, held_over} = {ref(), ref()}

    {:ok, _} = Credits.reserve(user_id, 5, spent, nil, @nov)
    {:ok, _} = Credits.consume(user_id, spent, @nov)
    {:ok, %{balance: 12}} = Credits.reserve(user_id, 3, held_over, nil, @nov)

    %{account: account} = Credits.overview(user_id, 1, @dec)
    assert %{period: "2026-12", allocation: 20, balance: 20, reserved: 3} = account

    assert [_, _, _, _, {"expiration", -12}, {"allocation", 20}] = kinds(user_id)

    # a November reservation released in December gives nothing back (its month has expired)
    assert {:ok, %{status: "released", refunded: 0, balance: 20, reserved: 0}} =
             Credits.release(user_id, held_over, @dec)

    assert Credits.resets_at(@nov) == ~U[2026-12-01 00:00:00Z]
  end

  test "upgrade: immediate top-up to the higher allowance, once; a downgrade takes nothing back" do
    user_id = uuid()
    {:ok, %{balance: 15}} = Credits.reserve(user_id, 5, ref(), nil, @nov)

    subscribe(user_id, "premium")
    :ok = Credits.sync_plan(user_id, @nov)

    assert %{account: %{allocation: 300, balance: 295, plan: "premium"}} =
             Credits.overview(user_id, 1, @nov)

    :ok = Credits.sync_plan(user_id, @nov)
    subscribe(user_id, "vip")
    :ok = Credits.sync_plan(user_id, @nov)
    subscribe(user_id, "free", status: "canceled")
    :ok = Credits.sync_plan(user_id, @nov)

    assert %{account: %{allocation: 1000, balance: 995}} = Credits.overview(user_id, 1, @nov)

    assert [{"allocation", 20}, {"reservation", -5}, {"top_up", 280}, {"top_up", 700}] =
             kinds(user_id)

    assert ["2026-11:premium", "2026-11:vip"] =
             Repo.all(
               from e in CreditEntry,
                 where: e.user_id == ^user_id and e.kind == "top_up",
                 order_by: e.seq,
                 select: e.ref
             )

    # the next month follows the effective plan (free)
    assert %{account: %{allocation: 20, balance: 20}} = Credits.overview(user_id, 1, @dec)
  end

  test "sync_plan creates nothing for a user without credit account" do
    user_id = uuid()
    subscribe(user_id, "vip")
    :ok = Credits.sync_plan(user_id)
    refute Repo.get(CreditAccount, user_id)
  end

  test "operations publish {:credits_changed, user_id, balance} on user:<id>" do
    user_id = uuid()
    MlShared.Events.subscribe(MlShared.Events.user(user_id))
    {:ok, _} = Credits.reserve(user_id, 4, ref(), nil, @nov)
    assert_receive {:credits_changed, ^user_id, 16}
  end

  test "parameters of the internal calls" do
    assert {:ok, %{amount: 2, ref: "studio:gen:x1", reason: "outline"}} =
             Credits.params(
               %{
                 "user_id" => uuid(),
                 "amount" => 2,
                 "ref" => "studio:gen:x1",
                 "reason" => "outline"
               },
               "studio",
               [:user_id, :amount, :ref]
             )

    assert {:error, changeset} =
             Credits.params(
               %{"user_id" => "nope", "amount" => 0, "ref" => "learning:x"},
               "studio",
               [:user_id, :amount, :ref]
             )

    assert %{user_id: [_], amount: [_], ref: ["must start with \"studio:\""]} =
             errors_on(changeset)
  end

  defp errors_on(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
end
