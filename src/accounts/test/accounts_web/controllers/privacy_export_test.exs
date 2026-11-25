defmodule MlAccountsWeb.PrivacyExportTest do
  use MlAccountsWeb.ConnCase, async: true
  use Oban.Testing, repo: MlAccounts.Repo
  import Ecto.Query, only: [from: 2]
  alias MlAccounts.{DataExport, Privacy}
  alias MlAccounts.Privacy.ExportWorker

  @moduletag :capture_log
  @services ~w(learning billing social multiplayer community studio notifications)

  setup do
    user = user_fixture(%{display_name: "Léa Moreau", bio: "Botanist."})
    MlShared.Events.subscribe("user:#{user.id}")
    %{user: user}
  end

  # Faux services (en-tête `x-ml-service` posé par MlShared.Client) : chaque appel est rapporté au test.
  defp stub_services(down \\ []) do
    test = self()

    Req.Test.stub(MlShared.Client, fn conn ->
      [service] = Plug.Conn.get_req_header(conn, "x-ml-service")
      send(test, {:called, conn.method, service, conn.request_path})

      if service in down,
        do: Req.Test.transport_error(conn, :econnrefused),
        else: Req.Test.json(conn, %{"data" => %{"from" => service}})
    end)
  end

  # Services appelés depuis le dernier relevé (et vidage de la boîte aux lettres).
  defp calls(acc \\ []) do
    receive do
      {:called, method, service, _path} -> calls([{method, service} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp as(user), do: build_conn() |> internal(user.id)

  defp request_export(user, password \\ password()),
    do: user |> as() |> post("/api/me/exports", %{password: password})

  defp run_export(id, attempt \\ 1),
    do: perform_job(ExportWorker, %{export_id: id}, attempt: attempt, max_attempts: 6)

  test "re-authentication, then an asynchronous job assembles accounts and the 7 services", %{
    user: user
  } do
    assert request_export(user, "wrong password!") |> json_response(401)
    refute_enqueued(worker: ExportWorker)

    assert %{"id" => id, "status" => "pending"} = request_export(user) |> json_response(202)
    assert_enqueued(worker: ExportWorker, args: %{export_id: id})
    assert_receive {:data_export_changed, _}

    stub_services()
    assert :ok = run_export(id)

    for service <- @services,
        do: assert_received({:called, "GET", ^service, "/api/internal/users/" <> _})

    assert_receive {:data_export_changed, _}

    assert %{"exports" => [%{"id" => ^id, "status" => "ready", "expires_at" => expires_at}]} =
             user |> as() |> get("/api/me/exports") |> json_response(200)

    {:ok, expires_at, _} = DateTime.from_iso8601(expires_at)
    assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 24 * 3600, 60

    document = user |> as() |> get("/api/me/exports/#{id}/download") |> json_response(200)
    assert document["format"] == "mysticlore-export/1"
    assert document["user_id"] == user.id
    assert Map.keys(document["services"]) |> Enum.sort() == Enum.sort(["accounts" | @services])
    assert document["services"]["learning"] == %{"from" => "learning"}

    profile = document["services"]["accounts"]["profile"]
    assert profile["email"] == user.email
    assert profile["display_name"] == "Léa Moreau"
    refute inspect(document) =~ "hashed_password"
    assert %{"enabled" => false} = document["services"]["accounts"]["two_factor"]
  end

  test "an unavailable service is retried alone, then the export completes", %{user: user} do
    %{"id" => id} = request_export(user) |> json_response(202)

    stub_services(["billing", "studio"])
    assert {:error, {:unavailable, ["billing", "studio"]}} = run_export(id)
    assert length(calls()) == 7

    assert %DataExport{status: "pending", failed_services: ["billing", "studio"]} =
             Repo.get!(DataExport, id)

    assert user |> as() |> get("/api/me/exports/#{id}/download") |> json_response(409)

    stub_services()
    assert :ok = run_export(id, 2)
    assert calls() == [{"GET", "billing"}, {"GET", "studio"}]

    assert %DataExport{status: "ready", failed_services: []} = Repo.get!(DataExport, id)

    assert %{"services" => %{"billing" => _, "learning" => _}} =
             user |> as() |> get("/api/me/exports/#{id}/download") |> json_response(200)
  end

  test "after the last attempt the export fails and names the services", %{user: user} do
    %{"id" => id} = request_export(user) |> json_response(202)

    stub_services(["social"])
    assert :ok = run_export(id, 6)

    assert %{"exports" => [%{"status" => "failed", "failed_services" => ["social"]}]} =
             user |> as() |> get("/api/me/exports") |> json_response(200)

    assert %{"error" => "not_ready"} =
             user |> as() |> get("/api/me/exports/#{id}/download") |> json_response(409)

    assert Repo.get!(DataExport, id).data == nil
  end

  test "the result expires after 24 hours and is then purged", %{user: user} do
    %{"id" => id} = request_export(user) |> json_response(202)
    stub_services()
    :ok = run_export(id)

    past = DateTime.add(DateTime.utc_now(:second), -60)
    Repo.update_all(from(e in DataExport, where: e.id == ^id), set: [expires_at: past])

    assert %{"exports" => [%{"status" => "expired"}]} =
             user |> as() |> get("/api/me/exports") |> json_response(200)

    assert %{"error" => "expired"} =
             user |> as() |> get("/api/me/exports/#{id}/download") |> json_response(410)

    assert Privacy.purge_expired_exports() == 1
    assert user |> as() |> get("/api/me/exports/#{id}/download") |> json_response(404)
  end

  test "at most 3 exports per 24 hours", %{user: user} do
    for _ <- 1..3, do: assert(request_export(user) |> json_response(202))

    assert %{"error" => "rate_limited"} = request_export(user) |> json_response(429)
    assert Repo.aggregate(DataExport, :count) == 3
  end

  test "only the owner sees and downloads an export (IDOR → 404)", %{user: user} do
    %{"id" => id} = request_export(user) |> json_response(202)
    stub_services()
    :ok = run_export(id)

    other = user_fixture()
    assert %{"exports" => []} = other |> as() |> get("/api/me/exports") |> json_response(200)

    assert %{"error" => "not_found"} =
             other |> as() |> get("/api/me/exports/#{id}/download") |> json_response(404)

    assert user |> as() |> get("/api/me/exports/not-a-uuid/download") |> json_response(404)
    assert build_conn() |> get("/api/me/exports/#{id}/download") |> json_response(401)
  end

  test "a wrong password counts towards the shared password lock", %{user: user} do
    for _ <- 1..5, do: assert(request_export(user, "wrong password!") |> json_response(401))
    assert %{"error" => "locked"} = request_export(user) |> json_response(429)
  end
end
