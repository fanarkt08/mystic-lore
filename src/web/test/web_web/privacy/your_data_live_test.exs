defmodule MysticWeb.Privacy.YourDataLiveTest do
  use MysticWeb.ConnCase, async: true

  @scheduled "2026-12-23T10:00:00Z"

  defp export(id, status, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "status" => status,
        "failed_services" => [],
        "inserted_at" => "2026-11-23T09:00:00Z",
        "completed_at" => nil,
        "expires_at" => nil
      },
      attrs
    )
  end

  defp routes(user, exports, extra \\ %{}) do
    user
    |> member_routes()
    |> Map.merge(%{
      {"GET", "/api/me/2fa"} => %{
        "enabled" => false,
        "enabled_at" => nil,
        "recovery_codes_left" => 0
      },
      {"GET", "/api/me/sessions"} => %{"sessions" => []},
      {"GET", "/api/me/exports"} => %{"exports" => exports}
    })
    |> Map.merge(extra)
  end

  setup do
    %{user: user_fixture()}
  end

  describe "exports" do
    test "lists the exports with their status; a ready one has a download link", %{
      conn: conn,
      user: user
    } do
      stub_api(
        routes(user, [
          export("e-ready", "ready", %{"expires_at" => "2026-11-24T09:01:00Z"}),
          export("e-wait", "pending", %{"failed_services" => ["billing"]}),
          export("e-fail", "failed", %{"failed_services" => ["social", "studio"]})
        ])
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/data")

      assert has_element?(view, "#your-data")
      assert has_element?(view, "#export-e-ready", "Ready")
      assert has_element?(view, "#download-e-ready[href='/settings/exports/e-ready/download']")
      assert has_element?(view, "#export-e-wait", "Waiting for membership")
      refute has_element?(view, "#download-e-wait")
      assert has_element?(view, "#export-e-fail", "friends and messages, studio")
      refute has_element?(view, "#download-e-fail")
    end

    test "requesting needs the password; the list then reloads, in real time too", %{
      conn: conn,
      user: user
    } do
      stub_api(
        routes(user, [], %{
          {"POST", "/api/me/exports"} => fn _conn, %{"password" => password} ->
            if password == "my-password",
              do: {202, %{"id" => "e1", "status" => "pending"}},
              else: {401, %{"error" => "invalid_credentials"}}
          end
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/data")
      assert has_element?(view, "#no-exports")

      view |> form("#export-form", data_export: %{password: "wrong"}) |> render_submit()
      assert has_element?(view, "#export-form", "This is not your current password.")

      stub_api(
        routes(user, [export("e1", "pending")], %{
          {"POST", "/api/me/exports"} => {202, %{"id" => "e1", "status" => "pending"}}
        })
      )

      view |> form("#export-form", data_export: %{password: "my-password"}) |> render_submit()
      assert_received {:api, %{method: "POST", path: "/api/me/exports"}}
      assert has_element?(view, "#export-e1", "Preparing")

      # the export job publishes {:data_export_changed, id} on "user:<id>"
      stub_api(routes(user, [export("e1", "ready", %{"expires_at" => "2026-11-24T09:00:00Z"})]))
      send(view.pid, {:data_export_changed, user["id"]})
      assert has_element?(view, "#download-e1")
    end

    test "the Refresh button reloads; the daily limit is explained", %{conn: conn, user: user} do
      stub_api(
        routes(user, [], %{
          {"POST", "/api/me/exports"} => {429, %{"error" => "rate_limited"}}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/data")

      view |> form("#export-form", data_export: %{password: "my-password"}) |> render_submit()
      assert render(view) =~ "at most 3 exports per day"

      stub_api(routes(user, [export("e2", "ready")]))
      view |> element("#refresh-exports") |> render_click()
      assert has_element?(view, "#download-e2")
    end
  end

  describe "account deletion" do
    test "explains what is deleted, kept and billed; wrong username refused", %{
      conn: conn,
      user: user
    } do
      stub_api(
        routes(user, [], %{
          {"POST", "/api/me/deletion"} =>
            {422,
             %{
               "error" => "invalid",
               "errors" => %{"confirm_username" => ["does not match your username"]}
             }}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/data")

      assert has_element?(view, "#account-deletion", "Deleted")
      assert has_element?(view, "#account-deletion", "Deleted member")
      assert has_element?(view, "#account-deletion", "Invoices and the AI credit ledger are kept")
      refute has_element?(view, "#deletion-banner")

      view
      |> form("#deletion-form",
        account_deletion: %{password: "my-password", confirm_username: "nope"}
      )
      |> render_submit()

      assert has_element?(view, "#deletion-form", "does not match your username")
    end

    test "scheduling signs out to the login page with the date", %{conn: conn, user: user} do
      stub_api(
        routes(user, [], %{
          {"POST", "/api/me/deletion"} => %{"deletion_scheduled_at" => @scheduled}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/data")

      result =
        view
        |> form("#deletion-form",
          account_deletion: %{password: "my-password", confirm_username: " lea_moreau "}
        )
        |> render_submit()

      # every session was revoked by accounts: the login page shows the date
      stub_api(%{{"GET", "/api/sessions/current"} => {401, %{"error" => "unauthorized"}}})
      assert {:ok, conn} = follow_redirect(result, conn)
      assert html_response(conn, 200) =~ "Dec 23, 2026"

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/me/deletion",
                         body: %{
                           "password" => "my-password",
                           "confirm_username" => "lea_moreau"
                         }
                       }}
    end
  end

  describe "banner while a deletion is scheduled" do
    test "settings: banner with the date, cancel reloads the member", %{conn: conn} do
      user = user_fixture(%{"deletion_scheduled_at" => @scheduled})
      stub_api(routes(user, []))

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/data")
      assert has_element?(view, "#deletion-banner", "Dec 23, 2026")
      refute has_element?(view, "#deletion-form")

      stub_api(
        routes(Map.put(user, "deletion_scheduled_at", nil), [], %{
          {"DELETE", "/api/me/deletion"} => {204, nil}
        })
      )

      view |> element("#cancel-deletion") |> render_click()
      assert_received {:api, %{method: "DELETE", path: "/api/me/deletion"}}
      refute has_element?(view, "#deletion-banner")
      assert has_element?(view, "#deletion-form")
      assert render(view) =~ "Deletion cancelled"
    end

    test "dashboard: banner and cancel", %{conn: conn} do
      user = user_fixture(%{"deletion_scheduled_at" => @scheduled})

      dashboard_routes = %{
        {"GET", "/api/me/dashboard"} => :unavailable,
        {"GET", "/api/me/billing"} => :unavailable,
        {"GET", "/api/me/friend-requests"} => :unavailable
      }

      stub_api(Map.merge(member_routes(user), dashboard_routes))
      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      assert has_element?(view, "#deletion-banner", "Dec 23, 2026")

      stub_api(
        user
        |> Map.put("deletion_scheduled_at", nil)
        |> member_routes()
        |> Map.merge(dashboard_routes)
        |> Map.put({"DELETE", "/api/me/deletion"}, {204, nil})
      )

      view |> element("#cancel-deletion") |> render_click()
      refute has_element?(view, "#deletion-banner")
    end

    test "dashboard: no banner without a scheduled deletion", %{conn: conn, user: user} do
      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/dashboard"} => :unavailable,
          {"GET", "/api/me/billing"} => :unavailable,
          {"GET", "/api/me/friend-requests"} => :unavailable
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      refute has_element?(view, "#deletion-banner")
    end
  end

  describe "download" do
    test "proxies the JSON as an attachment, for the session's member", %{conn: conn, user: user} do
      document = %{"format" => "mysticlore-export/1", "user_id" => user["id"], "services" => %{}}
      test = self()

      stub_api(
        Map.put(member_routes(user), {"GET", "/api/me/exports/e1/download"}, fn conn, _ ->
          ["Bearer " <> token] = Plug.Conn.get_req_header(conn, "authorization")
          {:ok, %{"sub" => sub}} = MlShared.InternalToken.verify(token)
          send(test, {:download_as, sub})
          document
        end)
      )

      conn = conn |> log_in() |> get(~p"/settings/exports/e1/download")

      assert response(conn, 200) |> Jason.decode!() == document
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/^attachment; filename="mysticlore-data-\d{4}-\d{2}-\d{2}\.json"$/
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      user_id = user["id"]
      assert_received {:download_as, ^user_id}
    end

    test "someone else's (or an expired) export: back to settings, nothing served", %{
      conn: conn,
      user: user
    } do
      stub_api(
        Map.put(
          member_routes(user),
          {"GET", "/api/me/exports/theirs/download"},
          {404, %{"error" => "not_found"}}
        )
      )

      conn = conn |> log_in() |> get(~p"/settings/exports/theirs/download")
      # explained by the data section, with the next step
      assert redirected_to(conn) == "/settings/data?export=missing"
    end

    test "an expired export: the data section says so and points to a new export", %{
      conn: conn,
      user: user
    } do
      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/exports/old/download"} => {410, %{"error" => "expired"}},
          {"GET", "/api/me/exports"} => %{"exports" => []}
        })

      stub_api(routes)
      conn = conn |> log_in() |> get(~p"/settings/exports/old/download")
      assert redirected_to(conn) == "/settings/data?export=expired"

      {:ok, view, _html} = build_conn() |> log_in() |> live(~p"/settings/data?export=expired")
      assert has_element?(view, "#export-link-state", "This download link has expired")
      assert has_element?(view, "#export-link-state a[href='#your-data']")
      # an unknown value shows nothing
      {:ok, view, _html} = build_conn() |> log_in() |> live(~p"/settings/data?export=nope")
      refute has_element?(view, "#export-link-state")
    end

    test "anonymous: to the login page", %{conn: conn} do
      stub_api(%{{"GET", "/api/sessions/current"} => {401, %{"error" => "unauthorized"}}})
      conn = conn |> log_in() |> get(~p"/settings/exports/e1/download")
      assert redirected_to(conn) == "/login?return_to=%2Fsettings%2Fdata"
    end
  end

  test "login refused while the deletion is in progress", %{conn: conn} do
    stub_api(%{{"POST", "/api/sessions"} => {403, %{"error" => "account_deleted"}}})

    conn =
      post(conn, ~p"/login", user: %{email: "lyra@mysticlore.test", password: "my-password"})

    assert html_response(conn, 403) =~ "This account is being deleted"
  end
end
