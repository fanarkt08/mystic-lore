defmodule MlBillingWeb.AdminTest do
  use MlBillingWeb.ConnCase, async: true
  alias MlBilling.{CreditEntry, Invoice, Subscription, WebhookEvent}

  @moduletag :capture_log

  setup do
    %{admin: uuid(), member: uuid()}
  end

  # Faux accounts : rôles (`roles`), membres connus, journal d'audit (`audit: :down`). Appels rapportés au test.
  defp stub_accounts(roles, opts \\ []) do
    test = self()

    Req.Test.stub(MlShared.Client, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:accounts, conn.method, conn.request_path, raw != "" && Jason.decode!(raw)})

      case {conn.method, conn.request_path} do
        {"GET", "/api/internal/users/" <> id} ->
          if Map.has_key?(roles, id),
            do: Req.Test.json(conn, %{"user" => %{"id" => id, "role" => roles[id]}}),
            else: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})

        {"POST", "/api/internal/audit"} ->
          if opts[:audit] == :down,
            do: Req.Test.transport_error(conn, :econnrefused),
            else: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end
    end)
  end

  defp call(method, path, user, body \\ nil) do
    conn = build_conn() |> as_user(user)

    if body,
      do:
        conn
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, path, Jason.encode!(body)),
      else: dispatch(conn, @endpoint, method, path)
  end

  defp subscribe!(user_id, plan, status) do
    Repo.insert!(%Subscription{
      user_id: user_id,
      plan: plan,
      status: status,
      provider: "local",
      current_period_end: DateTime.add(DateTime.utc_now(:second), 30, :day)
    })
  end

  test "admin only: a moderator and a VIP member get 403 (role ≠ plan)", %{admin: admin} do
    vip = uuid()
    mod = uuid()
    subscribe!(vip, "vip", "active")
    stub_accounts(%{admin => "admin", vip => "user", mod => "moderator"})

    for user <- [vip, mod],
        path <- ~w(/api/admin/stats /api/admin/subscriptions /api/admin/webhook-events) do
      assert %{"error" => "forbidden"} = call(:get, path, user) |> json_response(403)
    end

    assert %{"error" => "forbidden"} =
             call(:post, "/api/admin/credits/adjustments", mod, %{}) |> json_response(403)

    assert %{"stats" => %{"active_subscriptions" => %{"vip" => 1, "premium" => 0}}} =
             call(:get, "/api/admin/stats", admin) |> json_response(200)
  end

  test "stats, subscriptions and failed webhook events are read-only views", %{admin: admin} do
    stub_accounts(%{admin => "admin"})
    user = uuid()
    subscribe!(user, "premium", "past_due")

    Repo.insert!(%Invoice{
      user_id: user,
      provider: "local",
      provider_invoice_id: "in_1",
      amount_cents: 1200,
      currency: "usd",
      status: "paid"
    })

    Repo.insert!(%WebhookEvent{
      provider: "stripe",
      provider_event_id: "evt_1",
      type: "customer.subscription.updated",
      event_created_at: DateTime.utc_now(:second),
      status: "failed",
      error: "unknown_price",
      payload: %{"secret" => "never shown"}
    })

    assert %{
             "stats" => %{
               "revenue_month_cents" => 1200,
               "currency" => "usd",
               "past_due_subscriptions" => 1,
               "failed_webhook_events" => 1
             }
           } = call(:get, "/api/admin/stats", admin) |> json_response(200)

    assert %{"entries" => [%{"user_id" => ^user, "status" => "past_due"}], "total" => 1} =
             call(:get, "/api/admin/subscriptions?status=past_due", admin) |> json_response(200)

    body = call(:get, "/api/admin/webhook-events", admin) |> response(200)

    assert %{"entries" => [%{"error" => "unknown_price", "provider_event_id" => "evt_1"}]} =
             Jason.decode!(body)

    refute body =~ "never shown"

    # no route changes a subscription from the admin
    refute Enum.any?(MlBillingWeb.Router.__routes__(), fn r ->
             String.starts_with?(r.path, "/api/admin") and r.verb != :get and
               not String.starts_with?(r.path, "/api/admin/credits")
           end)
  end

  test "credit adjustment: validated, idempotent by ref, audited in the transaction", ctx do
    %{admin: admin, member: member} = ctx
    stub_accounts(%{admin => "admin", member => "user"})
    ref = "admin:" <> Ecto.UUID.generate()
    body = %{user_id: member, amount: 50, reason: "Contest prize", ref: ref}
    path = "/api/admin/credits/adjustments"

    assert %{"errors" => errors} =
             call(:post, path, admin, %{body | amount: 0, reason: "x", ref: "studio:1"})
             |> json_response(422)

    assert Map.keys(errors) |> Enum.sort() == ~w(amount reason ref)

    assert %{"errors" => %{"user_id" => _}} =
             call(:post, path, admin, %{body | user_id: uuid()}) |> json_response(422)

    assert %{"adjustment" => %{"status" => "applied", "amount" => 50, "balance" => balance}} =
             call(:post, path, admin, body) |> json_response(201)

    assert_received {:accounts, "POST", "/api/internal/audit",
                     %{
                       "action" => "billing.credits.adjusted",
                       "actor_id" => ^admin,
                       "target_id" => ^member,
                       "reason" => "Contest prize",
                       "metadata" => %{"amount" => 50, "ref" => ^ref}
                     }}

    assert %{"adjustment" => %{"status" => "duplicate", "balance" => ^balance}} =
             call(:post, path, admin, body) |> json_response(200)

    refute_received {:accounts, "POST", "/api/internal/audit", _}

    assert [%CreditEntry{kind: "adjustment", delta: 50}] =
             Repo.all(
               from e in CreditEntry, where: e.user_id == ^member and e.kind == "adjustment"
             )

    # audit log unreachable: nothing is credited
    stub_accounts(%{admin => "admin", member => "user"}, audit: :down)

    assert %{"error" => "audit_unavailable"} =
             call(:post, path, admin, %{body | ref: "admin:" <> Ecto.UUID.generate()})
             |> json_response(503)

    assert Repo.aggregate(
             from(e in CreditEntry, where: e.user_id == ^member and e.kind == "adjustment"),
             :count
           ) == 1
  end
end
