defmodule MlShared.NotificationsTest do
  use ExUnit.Case, async: false
  alias MlShared.{InternalToken, Notifications}

  @payload %{
    user_id: "00000000-0000-4000-8000-000000000001",
    category: "learning",
    kind: "badge_earned",
    params: %{badge_slug: "first-spark", badge_name: "Première étincelle"},
    dedupe_key: "badge:first-spark"
  }

  setup do
    Application.put_env(:ml_shared, :req_options, plug: {Req.Test, __MODULE__}, retry: false)
    Application.put_env(:ml_shared, :notifications_retry_delays, [0, 0])

    on_exit(fn ->
      Application.delete_env(:ml_shared, :req_options)
      Application.delete_env(:ml_shared, :notifications_retry_delays)
      Application.delete_env(:ml_shared, :notifications_async)
    end)
  end

  # Faux centre : chaque appel est rapporté au test, puis la réponse suivante de `responses` est rendue.
  defp center(responses) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      ["Bearer " <> token] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, claims} = InternalToken.verify(token)
      send(test, {:center, conn.method, conn.request_path, Jason.decode!(raw), claims})

      case Agent.get_and_update(agent, fn
             [next | rest] -> {next, rest}
             [] -> {201, []}
           end) do
        :down -> Req.Test.transport_error(conn, :econnrefused)
        status -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "x"})
      end
    end)
  end

  test "deliver: one signed attempt, outcome by status" do
    center([201, 403, 422, 503, :down])
    assert :ok = Notifications.deliver(@payload)
    assert_received {:center, "POST", "/api/internal/notifications", body, %{"sub" => nil}}
    assert body["kind"] == "badge_earned" and body["dedupe_key"] == "badge:first-spark"

    assert {:discard, {403, "x"}} = Notifications.deliver(@payload)
    assert {:discard, {422, "x"}} = Notifications.deliver(@payload)
    assert {:retry, {:http, 503}} = Notifications.deliver(@payload)
    assert {:retry, :unavailable} = Notifications.deliver(@payload)
  end

  test "notify retries a transient failure, never a refusal" do
    center([503, :down, 201])
    assert :ok = Notifications.notify(@payload)
    for _ <- 1..3, do: assert_received({:center, "POST", _, _, _})

    center([422, 201])
    assert {:error, {422, "x"}} = Notifications.notify(@payload)
    assert_received {:center, _, _, _, _}
    refute_received {:center, _, _, _, _}

    # retries exhausted: reported, not raised
    center([503, 503, 503])
    assert {:error, {:http, 503}} = Notifications.notify(@payload)
  end

  test "read and clear_between hit their internal routes" do
    center([200, 200])
    assert :ok = Notifications.read("u1", "conversation:c1", ~U[2026-11-24 10:00:00Z])

    assert_received {:center, "POST", "/api/internal/notifications/read",
                     %{"user_id" => "u1", "dedupe_key" => "conversation:c1", "read_at" => at}, _}

    assert at == "2026-11-24T10:00:00Z"
    assert :ok = Notifications.clear_between("u1", "u2")

    assert_received {:center, "POST", "/api/internal/notifications/clear-between",
                     %{"a" => "u1", "b" => "u2"}, _}
  end

  test "async never raises and runs in a supervised task (or inline when configured)" do
    test = self()
    assert :ok = Notifications.async(fn -> send(test, {:ran_in, self()}) end)
    assert_receive {:ran_in, pid}
    refute pid == self()

    Application.put_env(:ml_shared, :notifications_async, false)
    assert :ok = Notifications.async(fn -> send(test, {:ran_in, self()}) end)
    assert_received {:ran_in, pid}
    assert pid == self()

    # a crashing producer function never reaches the caller
    assert :ok = Notifications.async(fn -> raise "boom" end)
    assert :ok = Notifications.async(fn -> exit(:boom) end)
  end
end
