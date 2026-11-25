defmodule MlAccountsWeb.AdminTest do
  use MlAccountsWeb.ConnCase, async: true
  import Ecto.Query
  import Swoosh.TestAssertions
  alias MlAccounts.{AuditEntry, Repo, Staff, User}

  setup do
    %{
      member: user_fixture(%{email: "hugo.vale@example.test", display_name: "Hugo"}),
      moderator: staff_fixture("moderator"),
      admin: staff_fixture("admin")
    }
  end

  defp staff_fixture(role) do
    user = user_fixture()
    user |> Ecto.Changeset.change(role: role) |> Repo.update!()
  end

  defp call(method, path, user, body \\ nil) do
    conn = build_conn() |> internal(user && user.id)

    if body,
      do:
        conn
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, path, Jason.encode!(body)),
      else: dispatch(conn, @endpoint, method, path)
  end

  defp service_call(service, body) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign(service))
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, :post, "/api/internal/audit", Jason.encode!(body))
  end

  defp entries(action), do: Repo.all(from e in AuditEntry, where: e.action == ^action)

  describe "authorization" do
    test "a member gets 403 on every staff route; moderator ≠ admin", ctx do
      %{member: member, moderator: mod} = ctx

      for {method, path} <- [
            {:get, "/api/admin/stats"},
            {:get, "/api/admin/users"},
            {:get, "/api/admin/users/#{mod.id}"},
            {:post, "/api/admin/users/#{mod.id}/sanctions"},
            {:get, "/api/admin/appeals"},
            {:get, "/api/admin/incidents"},
            {:post, "/api/admin/incidents"},
            {:get, "/api/admin/audit"},
            {:get, "/api/admin/audit/export"},
            {:put, "/api/admin/users/#{mod.id}/role"}
          ] do
        assert %{"error" => "forbidden"} = call(method, path, member, %{}) |> json_response(403)
      end

      # moderator: members and stats yes; roles and audit no
      assert %{"stats" => %{"members" => _}} =
               call(:get, "/api/admin/stats", mod) |> json_response(200)

      for {method, path} <- [
            {:get, "/api/admin/audit"},
            {:get, "/api/admin/audit/export"},
            {:put, "/api/admin/users/#{member.id}/role"}
          ] do
        assert call(method, path, mod, %{role: "moderator", reason: "promotion"})
               |> json_response(403)
      end

      assert call(:get, "/api/admin/stats", nil) |> json_response(401)
    end

    test "the role comes from the database, never from the request", %{member: member} do
      body = %{role: "admin", user: %{role: "admin"}}

      assert call(:get, "/api/admin/users?role=admin", member, body) |> json_response(403)
    end
  end

  describe "members" do
    test "masked emails for moderators; full emails for admins, and the viewing is audited",
         ctx do
      %{member: member, moderator: mod, admin: admin} = ctx

      %{"entries" => entries} =
        call(:get, "/api/admin/users?q=member", mod) |> json_response(200)

      row = Enum.find(entries, &(&1["id"] == member.id)) || flunk("member listed")
      assert row["email"] == "h•••@example.test" and row["email_masked"]
      assert entries("accounts.members.listed") == []

      %{"entries" => entries} = call(:get, "/api/admin/users", admin) |> json_response(200)
      assert Enum.find(entries, &(&1["id"] == member.id))["email"] == "hugo.vale@example.test"
      assert [%AuditEntry{actor_id: actor}] = entries("accounts.members.listed")
      assert actor == admin.id

      assert %{"user" => %{"email" => "h•••@example.test", "sanctions" => []}} =
               call(:get, "/api/admin/users/#{member.id}", mod) |> json_response(200)

      assert %{"user" => %{"email" => "hugo.vale@example.test"}} =
               call(:get, "/api/admin/users/#{member.id}", admin) |> json_response(200)

      assert [%AuditEntry{target_id: target}] = entries("accounts.member.viewed")
      assert target == member.id

      # moderators can't search by email (no enumeration of addresses)
      assert %{"entries" => []} =
               call(:get, "/api/admin/users?q=hugo.vale@", mod) |> json_response(200)

      assert call(:get, "/api/admin/users/#{Ecto.UUID.generate()}", mod) |> json_response(404)
    end

    test "role change: admin only, reason required, never oneself, audited and published", ctx do
      %{member: member, moderator: mod, admin: admin} = ctx
      MlShared.Events.subscribe("members")
      path = "/api/admin/users/#{member.id}/role"

      assert %{"errors" => %{"reason" => _}} =
               call(:put, path, admin, %{role: "moderator"}) |> json_response(422)

      assert %{"errors" => %{"role" => _}} =
               call(:put, path, admin, %{role: "god", reason: "because"}) |> json_response(422)

      assert %{"user" => %{"role" => "moderator"}} =
               call(:put, path, admin, %{role: "moderator", reason: "Trusted helper"})
               |> json_response(200)

      member_id = member.id
      assert_receive {:role_changed, ^member_id}

      assert [%AuditEntry{metadata: %{"from" => "user", "to" => "moderator"}}] =
               entries("accounts.role.changed")

      # self-demotion refused (even to another staff role)
      assert %{"error" => "self"} =
               call(:put, "/api/admin/users/#{admin.id}/role", admin, %{
                 role: "user",
                 reason: "Stepping down"
               })
               |> json_response(403)

      assert Repo.reload!(admin).role == "admin"
      assert call(:put, path, mod, %{role: "user", reason: "nope"}) |> json_response(403)
    end

    test "the last admin is protected (stale admin actor) and mutual demotion keeps one admin",
         ctx do
      %{admin: admin} = ctx

      # only one admin in this test's view of the database: another admin already demoted meanwhile
      stale = staff_fixture("admin")
      stale |> Ecto.Changeset.change(role: "user") |> Repo.update!()

      assert {:error, :last_admin} =
               Staff.set_role(stale, admin.id, %{"role" => "user", "reason" => "Take over"})

      other = staff_fixture("admin")
      parent = self()

      results =
        [{admin, other}, {other, admin}]
        |> Enum.map(fn {actor, target} ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Staff.set_role(actor, target.id, %{"role" => "user", "reason" => "Demote rival"})
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Repo.aggregate(from(u in User, where: u.role == "admin"), :count) >= 1
    end
  end

  describe "sanctions and appeals" do
    test "restriction: bounded duration and reason; exposed by the internal route; audited",
         ctx do
      %{member: member, moderator: mod} = ctx
      path = "/api/admin/users/#{member.id}/sanctions"

      for body <- [
            %{kind: "restriction", reason: "Spam", duration_hours: 24},
            %{kind: "restriction", reason: "Spamming links", duration_hours: 0},
            %{kind: "restriction", reason: "Spamming links", duration_hours: 721},
            %{kind: "restriction", reason: "Spamming links"},
            %{kind: "ban", reason: "Spamming links"}
          ] do
        assert %{"error" => "invalid"} = call(:post, path, mod, body) |> json_response(422)
      end

      assert %{
               "sanction" => %{
                 "status" => "active",
                 "ends_at" => ends_at,
                 "kind" => "restriction"
               }
             } =
               call(:post, path, mod, %{
                 kind: "restriction",
                 reason: "Spamming links",
                 duration_hours: 48
               })
               |> json_response(201)

      assert %{"user" => %{"restricted_until" => ^ends_at}} =
               build_conn()
               |> internal()
               |> get("/api/internal/users/#{member.id}")
               |> json_response(200)

      assert [%AuditEntry{actor_id: actor, reason: "Spamming links"}] =
               entries("accounts.sanction.issued")

      assert actor == mod.id
      assert_email_sent(subject: "Your MysticLore account is restricted")

      # never on oneself nor on another staff member
      assert %{"error" => "self"} =
               call(:post, "/api/admin/users/#{mod.id}/sanctions", mod, %{
                 kind: "warning",
                 reason: "Testing myself"
               })
               |> json_response(403)

      assert %{"error" => "staff_target"} =
               call(:post, "/api/admin/users/#{ctx.admin.id}/sanctions", mod, %{
                 kind: "warning",
                 reason: "Testing staff"
               })
               |> json_response(409)
    end

    test "the same service ref is applied once", %{member: member, moderator: mod} do
      body = %{kind: "warning", reason: "Rude message", ref: "social:report:abc"}
      path = "/api/admin/users/#{member.id}/sanctions"

      assert %{"sanction" => %{"id" => id}, "replayed" => false} =
               call(:post, path, mod, body) |> json_response(201)

      assert %{"sanction" => %{"id" => ^id}, "replayed" => true} =
               call(:post, path, mod, body) |> json_response(200)

      assert length(entries("accounts.sanction.issued")) == 1
    end

    test "appeal: one open per sanction, decided by ANOTHER staff member; acceptance lifts it",
         ctx do
      %{member: member, moderator: mod, admin: admin} = ctx
      MlShared.Events.subscribe("user:#{member.id}")

      %{"sanction" => %{"id" => sanction_id}} =
        call(:post, "/api/admin/users/#{member.id}/sanctions", mod, %{
          kind: "restriction",
          reason: "Spamming links",
          duration_hours: 24
        })
        |> json_response(201)

      member_id = member.id
      assert_receive {:sanction_changed, ^member_id}
      assert_email_sent(subject: "Your MysticLore account is restricted")

      assert %{"sanctions" => [%{"id" => ^sanction_id, "appealable" => true} = own]} =
               call(:get, "/api/me/sanctions", member) |> json_response(200)

      refute Map.has_key?(own, "issued_by")
      appeal_path = "/api/me/sanctions/#{sanction_id}/appeal"

      assert %{"errors" => %{"body" => _}} =
               call(:post, appeal_path, member, %{body: "too short"}) |> json_response(422)

      # another member's sanction is not found
      assert call(:post, appeal_path, mod, %{body: "This is not my sanction at all."})
             |> json_response(404)

      assert %{"appeal" => %{"id" => appeal_id, "status" => "open"}} =
               call(:post, appeal_path, member, %{body: "Those links were course resources."})
               |> json_response(201)

      assert %{"error" => "appeal_open"} =
               call(:post, appeal_path, member, %{body: "Please, those links were resources."})
               |> json_response(409)

      assert %{"entries" => [%{"id" => ^appeal_id, "member" => %{"id" => ^member_id}}]} =
               call(:get, "/api/admin/appeals", admin) |> json_response(200)

      decide = "/api/admin/appeals/#{appeal_id}/decide"

      # the author of the sanction can't decide the appeal
      assert %{"error" => "same_staff"} =
               call(:post, decide, mod, %{decision: "accept", reason: "I was wrong"})
               |> json_response(403)

      assert call(:post, decide, member, %{decision: "accept", reason: "Self-service"})
             |> json_response(403)

      assert %{"appeal" => %{"status" => "accepted"}} =
               call(:post, decide, admin, %{decision: "accept", reason: "Links were legit"})
               |> json_response(200)

      assert %{"error" => "already_decided"} =
               call(:post, decide, admin, %{decision: "reject", reason: "Changed my mind"})
               |> json_response(409)

      assert %{"user" => %{"restricted_until" => nil}} =
               build_conn()
               |> internal()
               |> get("/api/internal/users/#{member.id}")
               |> json_response(200)

      assert %{"sanctions" => [%{"status" => "lifted", "appeal" => %{"status" => "accepted"}}]} =
               call(:get, "/api/me/sanctions", member) |> json_response(200)

      assert [%AuditEntry{actor_id: decider}] = entries("accounts.appeal.accepted")
      assert decider == admin.id
      assert_email_sent(subject: "Your appeal was accepted")
    end

    test "lift: reason required, only an active sanction", %{member: member, moderator: mod} do
      %{"sanction" => %{"id" => id}} =
        call(:post, "/api/admin/users/#{member.id}/sanctions", mod, %{
          kind: "warning",
          reason: "Be kind to others"
        })
        |> json_response(201)

      assert call(:post, "/api/admin/sanctions/#{id}/lift", mod, %{}) |> json_response(422)

      assert %{"sanction" => %{"status" => "lifted", "lift_reason" => "Issued by mistake"}} =
               call(:post, "/api/admin/sanctions/#{id}/lift", mod, %{reason: "Issued by mistake"})
               |> json_response(200)

      assert %{"error" => "not_active"} =
               call(:post, "/api/admin/sanctions/#{id}/lift", mod, %{reason: "Issued by mistake"})
               |> json_response(409)

      assert %{"sanctions" => [%{"appealable" => false}]} =
               call(:get, "/api/me/sanctions", member) |> json_response(200)
    end
  end

  describe "audit log" do
    test "internal writes: backend services only, no secret nor message content", ctx do
      body = %{
        actor_id: ctx.moderator.id,
        action: "social.report.evidence_viewed",
        target_type: "report",
        target_id: "r1",
        reason: "Checking the harassment report",
        metadata: %{"message_id" => "m1"}
      }

      assert %{"id" => _} = service_call("social", body) |> json_response(201)
      assert service_call("web", body) |> json_response(403)
      assert service_call("accounts", body) |> json_response(403)

      assert %{"errors" => %{"action" => _}} =
               service_call("community", body) |> json_response(422)

      for metadata <- [%{"body" => "hello"}, %{"nested" => %{"Password" => "x"}}, %{"token" => 1}] do
        assert %{"errors" => %{"metadata" => _}} =
                 service_call("social", %{body | metadata: metadata}) |> json_response(422)
      end

      assert %{"errors" => %{"actor_id" => _}} =
               service_call("social", Map.delete(body, :actor_id)) |> json_response(422)
    end

    test "append-only: the database refuses updates and deletes", %{admin: admin} do
      entry = MlAccounts.Audit.record!(admin.id, "test.done", "user", admin.id, "why")

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(e in AuditEntry, where: e.id == ^entry.id), set: [reason: "edited"])
      end
    end

    test "admin list with filters; CSV export escaped, capped and audited",
         %{admin: admin} = ctx do
      MlAccounts.Audit.record!(ctx.moderator.id, "sanction.issued", "user", "u1", "=HYPERLINK(1)")
      MlAccounts.Audit.record!(admin.id, "role.changed", "user", "u2", "+cmd|' /C calc'!A0")

      assert %{"entries" => [%{"action" => "accounts.sanction.issued", "actor" => actor}]} =
               call(:get, "/api/admin/audit?action=accounts.sanction", admin)
               |> json_response(200)

      assert actor["id"] == ctx.moderator.id

      assert %{"total" => 1} =
               call(:get, "/api/admin/audit?actor=#{admin.username}", admin)
               |> json_response(200)

      today = Date.utc_today() |> Date.to_iso8601()

      assert %{"total" => 2} =
               call(:get, "/api/admin/audit?from=#{today}&to=#{today}", admin)
               |> json_response(200)

      assert %{"errors" => %{"from" => _}} =
               call(:get, "/api/admin/audit?from=yesterday", admin) |> json_response(422)

      conn = call(:get, "/api/admin/audit/export", admin)
      assert response(conn, 200)
      assert ["text/csv" <> _] = get_resp_header(conn, "content-type")
      [header | rows] = String.split(conn.resp_body, "\r\n", trim: true)
      assert header =~ "id,inserted_at,service,actor_id"
      assert Enum.any?(rows, &(&1 =~ ",'=HYPERLINK(1),"))
      assert Enum.any?(rows, &(&1 =~ ",'+cmd|' /C calc'!A0,"))
      refute conn.resp_body =~ ~r/,=HYPERLINK/

      assert [%AuditEntry{actor_id: exporter, metadata: %{"rows" => 2}}] =
               entries("accounts.audit.exported")

      assert exporter == admin.id
    end

    test "CSV cells: quoting and formula neutralization" do
      cell = &(&1 |> MlAccounts.Audit.csv_cell() |> IO.iodata_to_binary())
      assert cell.("-2+3") == "'-2+3"
      assert cell.("@SUM(A1)") == "'@SUM(A1)"
      assert cell.("a,b") == ~s("a,b")
      assert cell.(~s(say "hi")) == ~s("say ""hi""")
      assert cell.("=1,2") == ~s("'=1,2")
      assert cell.(nil) == ""
    end
  end

  describe "incidents" do
    test "open, timeline, resolution requires a summary, then final", %{moderator: mod} = ctx do
      assert %{"incident" => %{"id" => id, "status" => "open", "updates" => [_]}} =
               call(:post, "/api/admin/incidents", mod, %{
                 title: "Lesson pages slow",
                 severity: "high",
                 body: "Several members report slow lessons."
               })
               |> json_response(201)

      assert call(:post, "/api/admin/incidents", mod, %{title: "x", severity: "high"})
             |> json_response(422)

      path = "/api/admin/incidents/#{id}/updates"

      assert %{"incident" => %{"status" => "investigating", "updates" => [_, _]}} =
               call(:post, path, mod, %{body: "Looking at the database.", status: "investigating"})
               |> json_response(200)

      assert %{"errors" => %{"summary" => _}} =
               call(:post, path, ctx.admin, %{body: "Fixed.", status: "resolved"})
               |> json_response(422)

      assert %{"incident" => %{"status" => "resolved", "summary" => "Missing index, added."}} =
               call(:post, path, ctx.admin, %{
                 body: "Fixed.",
                 status: "resolved",
                 summary: "Missing index, added."
               })
               |> json_response(200)

      assert %{"error" => "already_resolved"} =
               call(:post, path, mod, %{body: "One more thing."}) |> json_response(409)

      assert %{"entries" => [%{"id" => ^id}]} =
               call(:get, "/api/admin/incidents", mod) |> json_response(200)

      assert length(entries("accounts.incident.resolved")) == 1
    end
  end

  test "stats are real counts", %{member: member, moderator: mod} do
    Repo.update_all(from(u in User, where: u.id == ^member.id),
      set: [restricted_until: DateTime.add(DateTime.utc_now(:second), 3600)]
    )

    %{"stats" => stats} = call(:get, "/api/admin/stats", mod) |> json_response(200)

    assert stats["members"] ==
             Repo.aggregate(from(u in User, where: is_nil(u.deleted_at)), :count)

    assert stats["restricted"] >= 1

    assert Map.keys(stats) |> Enum.sort() ==
             ~w(confirmed members new_7d open_appeals open_incidents restricted sanctions_7d)
  end
end
