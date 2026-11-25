defmodule MlBillingWeb.CreditsApiTest do
  use MlBillingWeb.ConnCase, async: false
  alias MlBilling.CreditEntry

  defp as_service(conn, service),
    do: put_req_header(conn, "authorization", "Bearer " <> MlShared.InternalToken.sign(service))

  defp studio(conn), do: as_service(conn, "studio")

  test "internal routes: service token of an allowed caller only", %{conn: conn} do
    body = %{"user_id" => uuid(), "amount" => 2, "ref" => "studio:gen:1"}

    assert %{"error" => "unauthorized"} =
             conn |> post("/api/internal/credits/reserve", body) |> json_response(401)

    for service <- ["web", "learning"] do
      assert %{"error" => "forbidden"} =
               conn
               |> as_service(service)
               |> post("/api/internal/credits/reserve", body)
               |> json_response(403)
    end
  end

  test "reserve → consume / release, with 402 and 409 refusals", %{conn: conn} do
    user_id = uuid()
    body = %{"user_id" => user_id, "amount" => 12, "ref" => "studio:gen:a", "reason" => "image"}

    assert %{
             "ref" => "studio:gen:a",
             "status" => "held",
             "amount" => 12,
             "balance" => 8,
             "reserved" => 12
           } =
             conn |> studio() |> post("/api/internal/credits/reserve", body) |> json_response(200)

    # replay: same answer, nothing more held
    assert %{"status" => "held", "balance" => 8} =
             conn |> studio() |> post("/api/internal/credits/reserve", body) |> json_response(200)

    assert %{"error" => "insufficient_credits", "balance" => 8} =
             conn
             |> studio()
             |> post("/api/internal/credits/reserve", %{body | "ref" => "studio:gen:b"})
             |> json_response(402)

    ref = %{"user_id" => user_id, "ref" => "studio:gen:a"}

    assert %{"status" => "consumed", "balance" => 8, "reserved" => 0} =
             conn |> studio() |> post("/api/internal/credits/consume", ref) |> json_response(200)

    assert %{"error" => "already_consumed"} =
             conn |> studio() |> post("/api/internal/credits/release", ref) |> json_response(409)

    assert %{"error" => "not_found"} =
             conn
             |> studio()
             |> post("/api/internal/credits/consume", %{ref | "ref" => "studio:gen:zz"})
             |> json_response(404)

    assert %{"error" => "invalid", "errors" => %{"amount" => _, "user_id" => _}} =
             conn
             |> studio()
             |> post("/api/internal/credits/reserve", %{"ref" => "studio:x", "amount" => -1})
             |> json_response(422)
  end

  test "GET /api/me/credits: balance, monthly allocation and paginated history", %{conn: conn} do
    user_id = uuid()

    for i <- 1..20 do
      {:ok, _} = MlBilling.Credits.reserve(user_id, 1, "studio:gen:p#{i}", "outline")
    end

    me = as_user(conn, user_id)

    assert %{
             "balance" => 0,
             "reserved" => 20,
             "allocation" => 20,
             "plan" => "free",
             "period" => period,
             "resets_at" => resets_at,
             "entries" => [latest | _] = entries,
             "page" => 1,
             "total_pages" => 2,
             "total" => 21
           } = me |> get("/api/me/credits") |> json_response(200)

    assert period == MlBilling.Credits.period(DateTime.utc_now())
    assert {:ok, _, 0} = DateTime.from_iso8601(resets_at)
    assert length(entries) == 20

    assert %{
             "kind" => "reservation",
             "amount" => 1,
             "delta" => -1,
             "balance_after" => 0,
             "reason" => "outline",
             "ref" => "studio:gen:p20"
           } = latest

    assert %{"entries" => [%{"kind" => "allocation", "delta" => 20}], "page" => 2} =
             me |> get("/api/me/credits?page=2") |> json_response(200)

    assert %{"page" => 1} = me |> get("/api/me/credits?page=abc") |> json_response(200)

    assert %{"error" => "unauthorized"} =
             conn |> as_user(nil) |> get("/api/me/credits") |> json_response(401)
  end

  test "an upgrade paid through the webhook pipeline tops the month up at once", %{conn: conn} do
    user_id = uuid()
    me = as_user(conn, user_id)
    assert %{"balance" => 20} = me |> get("/api/me/credits") |> json_response(200)

    urls = %{"success_url" => "http://x.test/s", "cancel_url" => "http://x.test/c"}

    %{"session_id" => sid} =
      me |> post("/api/checkout", Map.put(urls, "plan", "premium")) |> json_response(201)

    me |> post("/api/checkout/#{sid}/simulate-payment", %{"outcome" => "succeeded"})

    # the entitlement change itself granted the difference (no credit call in between)
    assert [%CreditEntry{amount: 280, delta: 280}] =
             Repo.all(from e in CreditEntry, where: e.user_id == ^user_id and e.kind == "top_up")

    assert %{"balance" => 300, "allocation" => 300, "plan" => "premium"} =
             me |> get("/api/me/credits") |> json_response(200)
  end
end
