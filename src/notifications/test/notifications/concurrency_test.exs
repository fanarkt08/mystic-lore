defmodule MlNotifications.ConcurrencyTest do
  @moduledoc """
  Courses réelles : chaque création tourne hors sandbox, sur sa propre connexion et dans sa propre transaction
  validée. Le membre est un UUID aléatoire ; ses lignes sont supprimées à la fin.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  import MlNotifications.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias MlNotifications.{EmailLog, Inbox, Notification, Repo}

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    fake_accounts()
    me = uuid()

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from n in Notification, where: n.user_id == ^me)
        Repo.delete_all(from l in EmailLog, where: l.user_id == ^me)

        Repo.delete_all(
          from e in "notification_events", where: e.user_id == type(^me, :binary_id)
        )

        Repo.delete_all(
          from m in "notification_read_marks", where: m.user_id == type(^me, :binary_id)
        )

        Repo.delete_all(from j in Oban.Job, where: fragment("?->>'user_id' = ?", j.args, ^me))
      end)
    end)

    {:ok, me: me}
  end

  test "simultaneous events of one key: ONE unread notification, exact count", %{me: me} do
    conversation = uuid()

    results =
      1..12
      |> Task.async_stream(
        fn i ->
          unboxed(fn ->
            {:ok, result} =
              Inbox.create(
                "social",
                attrs("message_received", me, %{
                  "conversation_id" => conversation,
                  "event_id" => "message:#{i}"
                })
              )

            result.status
          end)
        end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.frequencies(results) == %{"created" => 1, "aggregated" => 11}

    assert [%Notification{count: 12, read_at: nil}] =
             unboxed(fn -> Repo.all(where(Notification, user_id: ^me)) end)
  end

  test "the same occurrence sent concurrently is counted once", %{me: me} do
    body = attrs("friend_request_received", me, %{"event_id" => "friend_request:r1"})

    statuses =
      1..8
      |> Task.async_stream(
        fn _ -> unboxed(fn -> elem(Inbox.create("social", body), 1).status end) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.frequencies(statuses) == %{"created" => 1, "duplicate" => 7}

    assert [%Notification{count: 1}] =
             unboxed(fn -> Repo.all(where(Notification, user_id: ^me)) end)
  end
end
