defmodule MlBilling.ConcurrencyTest do
  # Real concurrency: separate connections (sandbox in :auto mode, real commits), explicit cleanup.
  use ExUnit.Case, async: false
  import Ecto.Query
  import MlBilling.TestHelpers
  alias Ecto.Adapters.SQL.Sandbox
  alias MlBilling.{Repo, Subscription, WebhookEvent, Webhooks}

  setup do
    Sandbox.mode(Repo, :auto)
    use_stripe()
    user_id = uuid()

    on_exit(fn ->
      Repo.delete_all(from e in WebhookEvent, where: like(e.provider_event_id, "evt_par_%"))
      Repo.delete_all(from s in Subscription, where: s.user_id == ^user_id)
      Sandbox.mode(Repo, :manual)
    end)

    {:ok, user_id: user_id}
  end

  defp in_parallel(signed_events) do
    signed_events
    |> Enum.map(fn {raw, header} ->
      Task.async(fn -> Webhooks.handle("stripe", raw, header) end)
    end)
    |> Task.await_many(15_000)
  end

  test "the same signed event delivered 10 times in parallel has exactly one effect", %{
    user_id: uid
  } do
    MlShared.Events.subscribe(MlShared.Events.user(uid))
    event = event("customer.subscription.created", stripe_subscription(uid), id: "evt_par_same")

    results = in_parallel(List.duplicate(signed(event), 10))

    assert Enum.frequencies(results) == %{{:ok, "processed"} => 1, {:ok, "duplicate"} => 9}
    assert_receive {:entitlements_changed, ^uid, "premium"}
    refute_receive {:entitlements_changed, ^uid, _}

    assert Repo.aggregate(
             from(e in WebhookEvent, where: e.provider_event_id == "evt_par_same"),
             :count
           ) ==
             1

    assert Repo.aggregate(from(s in Subscription, where: s.user_id == ^uid), :count) == 1
  end

  test "distinct events for a new user in parallel: one row, the newest state wins", %{
    user_id: uid
  } do
    now = System.os_time(:second)

    events =
      for i <- 0..5 do
        status = if i == 5, do: "canceled", else: "active"
        object = stripe_subscription(uid, status: status)

        signed(
          event("customer.subscription.updated", object, id: "evt_par_#{i}", created: now - 5 + i)
        )
      end

    results = in_parallel(Enum.shuffle(events))

    assert Enum.all?(results, &match?({:ok, status} when status in ["processed", "stale"], &1))

    assert [%Subscription{status: "canceled", last_event_at: last}] =
             Repo.all(from s in Subscription, where: s.user_id == ^uid)

    assert DateTime.to_unix(last) == now
  end
end
