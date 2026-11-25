defmodule MlBilling.CreditsConcurrencyTest do
  # Real concurrency: separate connections (sandbox in :auto mode, real commits), explicit cleanup.
  use ExUnit.Case, async: false
  import Ecto.Query
  import MlBilling.TestHelpers
  alias Ecto.Adapters.SQL.Sandbox
  alias MlBilling.{CreditAccount, CreditEntry, Credits, Repo}

  setup do
    Sandbox.mode(Repo, :auto)
    user_id = uuid()

    on_exit(fn ->
      Repo.delete_all(from e in CreditEntry, where: e.user_id == ^user_id)
      Repo.delete_all(from a in CreditAccount, where: a.user_id == ^user_id)
      Sandbox.mode(Repo, :manual)
    end)

    {:ok, user_id: user_id}
  end

  defp in_parallel(n, fun),
    do: 1..n |> Enum.map(fn i -> Task.async(fn -> fun.(i) end) end) |> Task.await_many(15_000)

  defp count(user_id, kind),
    do:
      Repo.aggregate(
        from(e in CreditEntry, where: e.user_id == ^user_id and e.kind == ^kind),
        :count
      )

  test "30 parallel reservations on a fresh free account: 20 succeed, never below zero", %{
    user_id: uid
  } do
    results = in_parallel(30, fn i -> Credits.reserve(uid, 1, "studio:gen:par#{i}") end)

    assert Enum.count(results, &match?({:ok, %{status: "held"}}, &1)) == 20
    assert Enum.count(results, &match?({:error, {:insufficient_credits, 0}}, &1)) == 10

    assert %CreditAccount{balance: 0, reserved: 20, allocation: 20} = Repo.get(CreditAccount, uid)
    # one allocation only, despite 30 concurrent first operations
    assert count(uid, "allocation") == 1
    assert count(uid, "reservation") == 20
  end

  test "the same reservation replayed and released in parallel takes and refunds once", %{
    user_id: uid
  } do
    ref = "studio:gen:same"
    results = in_parallel(10, fn _ -> Credits.reserve(uid, 7, ref) end)
    assert Enum.all?(results, &match?({:ok, %{status: "held", amount: 7}}, &1))
    assert %CreditAccount{balance: 13} = Repo.get(CreditAccount, uid)

    releases = in_parallel(10, fn _ -> Credits.release(uid, ref) end)
    assert Enum.all?(releases, &match?({:ok, %{status: "released", refunded: 7}}, &1))
    assert %CreditAccount{balance: 20, reserved: 0} = Repo.get(CreditAccount, uid)
    assert count(uid, "reservation") == 1
    assert count(uid, "release") == 1
  end

  test "consume and release racing on one reservation: exactly one wins", %{user_id: uid} do
    ref = "studio:gen:race"
    {:ok, _} = Credits.reserve(uid, 5, ref)

    results =
      in_parallel(10, fn i ->
        if rem(i, 2) == 0, do: Credits.consume(uid, ref), else: Credits.release(uid, ref)
      end)

    assert count(uid, "consumption") + count(uid, "release") == 1

    {winner, loser_error, balance} =
      if count(uid, "consumption") == 1,
        do: {"consumed", :already_consumed, 15},
        else: {"released", :already_released, 20}

    # every call either sees the winning state or is refused with the matching conflict
    assert Enum.all?(results, fn
             {:ok, %{status: status}} -> status == winner
             {:error, error} -> error == loser_error
           end)

    assert %CreditAccount{balance: ^balance, reserved: 0} = Repo.get(CreditAccount, uid)
  end
end
