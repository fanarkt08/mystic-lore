defmodule MlAccountsWeb.SupportTest do
  @moduledoc """
  Demandes de support : envoi, validation, accusé de réception sans le texte soumis, limites par compte et par
  adresse, droits du staff, audit, réponse, rétention, export et suppression.
  """
  use MlAccountsWeb.ConnCase, async: true
  use Oban.Testing, repo: MlAccounts.Repo
  import Ecto.Query
  import Swoosh.TestAssertions

  alias MlAccounts.{
    AuditEntry,
    NotifyWorker,
    Repo,
    Support,
    SupportReply,
    SupportRequest,
    Throttle
  }

  @moduletag :capture_log
  @message "My quiz answer was refused although it matches the lesson text exactly."

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

  defp send_request(user, attrs) do
    call(
      :post,
      "/api/support/requests",
      user,
      Map.merge(%{"topic" => "bug", "message" => @message, "locale" => "en"}, attrs)
    )
  end

  defp visitor_request!(email \\ "visitor@example.test", attrs \\ %{}) do
    %{"request" => %{"id" => id}} =
      send_request(nil, Map.put(attrs, "email", email)) |> json_response(201)

    id
  end

  defp entries(action), do: Repo.all(from e in AuditEntry, where: e.action == ^action)

  describe "sending a request" do
    test "a visitor: stored with their address, acknowledged WITHOUT the submitted text" do
      body =
        send_request(nil, %{"email" => "  Visitor@Example.TEST ", "locale" => "fr"})
        |> json_response(201)

      assert %{
               "request" => %{"reference" => "REQ-" <> _ = reference, "status" => "open"},
               "acknowledgement" => "sent"
             } = body

      assert reference =~ ~r/^REQ-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$/
      request = Repo.get_by!(SupportRequest, reference: reference)
      assert %{email: "visitor@example.test", user_id: nil, topic: "bug", locale: "fr"} = request
      assert request.message == @message

      assert_email_sent(fn email ->
        assert email.to == [{"", "visitor@example.test"}]
        assert email.subject =~ reference
        assert email.text_body =~ "Signaler un problème"
        refute email.text_body =~ "quiz answer"
        refute email.subject =~ "quiz"
        true
      end)
    end

    test "a member: the account's address, not the one in the body" do
      member = user_fixture(%{email: "lea@example.test"})

      assert %{"request" => %{"id" => id}} =
               send_request(member, %{"email" => "someone.else@example.test"})
               |> json_response(201)

      assert %{user_id: user_id, email: nil} = Repo.get!(SupportRequest, id)
      assert user_id == member.id

      assert_email_sent(fn email ->
        assert email.to == [{"", "lea@example.test"}]
        assert email.text_body =~ "/contact"
        refute email.text_body =~ "quiz answer"
        true
      end)

      refute_email_sent()
    end

    test "validation: topic, bounds, control characters, address", %{member: member} do
      assert %{"errors" => errors} =
               send_request(nil, %{"topic" => "ads", "message" => "short", "email" => "nope"})
               |> json_response(422)

      assert errors == %{
               "topic" => ["is invalid"],
               "message" => ["should be at least 10 character(s)"],
               "email" => ["must have the @ sign and no spaces"]
             }

      for message <- [
            "Hello\u0007 there, my lesson is broken",
            "Reversed \u202Etext inside a message"
          ] do
        assert %{"errors" => %{"message" => ["must not contain control characters"]}} =
                 send_request(member, %{"message" => message}) |> json_response(422)
      end

      # line breaks and tabs are fine
      assert %{"request" => _} =
               send_request(member, %{
                 "message" => "Line one\r\nLine two\twith a tab, still fine."
               })
               |> json_response(201)

      assert %{"errors" => %{"message" => ["should be at most 4000 character(s)"]}} =
               send_request(member, %{"message" => String.duplicate("a", 4001)})
               |> json_response(422)

      assert %{"errors" => %{"email" => ["can't be blank"]}} =
               send_request(nil, %{}) |> json_response(422)

      assert %{"errors" => %{"email" => ["is invalid"]}} =
               send_request(nil, %{"email" => "x@deleted.invalid"}) |> json_response(422)

      assert Repo.aggregate(SupportRequest, :count) == 1
    end

    test "an unknown or deleting member in the token is refused (401)" do
      assert %{"error" => "unauthorized"} =
               call(:post, "/api/support/requests", %{id: Ecto.UUID.generate()}, %{
                 "topic" => "bug",
                 "message" => @message
               })
               |> json_response(401)

      user = user_fixture()

      user
      |> Ecto.Changeset.change(
        deletion_scheduled_at: DateTime.add(DateTime.utc_now(:second), -60)
      )
      |> Repo.update!()

      assert send_request(user, %{}) |> json_response(401)
    end
  end

  describe "rate limits" do
    test "3 requests per day for one target address, whoever sends them" do
      for _ <- 1..3, do: visitor_request!("target@example.test")

      assert %{"error" => "rate_limited"} =
               send_request(nil, %{"email" => "TARGET@example.test"}) |> json_response(429)

      # another address is not affected; the address never appears in clear in the limits table
      visitor_request!("other@example.test")
      refute Repo.exists?(from t in Throttle, where: like(t.key, "%target@%"))
      assert Repo.aggregate(SupportRequest, :count) == 4
    end

    test "5 requests per day for one account; visitors typing the member's address don't block them" do
      member = user_fixture(%{email: "member.target@example.test"})
      # three visitors use the member's address: their own quota, not the member's
      for _ <- 1..3, do: visitor_request!("member.target@example.test")

      for _ <- 1..5, do: assert(send_request(member, %{}) |> json_response(201))
      assert %{"error" => "rate_limited"} = send_request(member, %{}) |> json_response(429)
      assert Repo.aggregate(where(SupportRequest, user_id: ^member.id), :count) == 5
      refute Repo.exists?(from t in Throttle, where: like(t.key, "%member.target%"))
    end
  end

  describe "staff" do
    test "a member gets 403 on every staff route", %{member: member} do
      id = visitor_request!()

      for {method, path} <- [
            {:get, "/api/admin/support/requests"},
            {:get, "/api/admin/support/requests/#{id}"},
            {:post, "/api/admin/support/requests/#{id}/replies"},
            {:patch, "/api/admin/support/requests/#{id}"}
          ] do
        assert %{"error" => "forbidden"} =
                 call(method, path, member, %{"body" => "x"}) |> json_response(403)
      end

      assert call(:get, "/api/admin/support/requests", nil) |> json_response(401)
      assert entries("accounts.support.viewed") == []
    end

    test "list without the text; masked address for a moderator, full for an admin (audited)",
         ctx do
      %{moderator: mod, admin: admin} = ctx
      visitor_request!("visitor@example.test")
      send_request(ctx.member, %{"topic" => "privacy"}) |> json_response(201)

      %{"entries" => entries, "total" => 2} =
        call(:get, "/api/admin/support/requests?status=open", mod) |> json_response(200)

      assert Enum.all?(entries, &(&1["requester"]["email_masked"] == true))
      assert Enum.any?(entries, &(&1["requester"]["email"] == "v•••@example.test"))

      assert Enum.any?(
               entries,
               &(&1["requester"]["kind"] == "member" and
                   &1["requester"]["member"]["display_name"] == "Hugo")
             )

      refute Enum.any?(entries, &Map.has_key?(&1, "message"))
      assert entries("accounts.support.listed") == []

      %{"entries" => entries} =
        call(:get, "/api/admin/support/requests?topic=privacy", admin) |> json_response(200)

      assert [%{"requester" => %{"email" => "hugo.vale@example.test", "email_masked" => false}}] =
               entries

      assert [%AuditEntry{actor_id: actor}] = entries("accounts.support.listed")
      assert actor == admin.id

      # search by reference (prefix, case-insensitive)
      [%{reference: reference}] = Repo.all(from r in SupportRequest, where: r.topic == "privacy")

      assert %{"total" => 1} =
               call(:get, "/api/admin/support/requests?q=#{String.downcase(reference)}", mod)
               |> json_response(200)
    end

    test "the detail is audited before it is returned; unknown or malformed id → 404", ctx do
      id = visitor_request!()

      assert %{"request" => %{"message" => @message, "internal_note" => nil, "replies" => []}} =
               call(:get, "/api/admin/support/requests/#{id}", ctx.moderator)
               |> json_response(200)

      assert [%AuditEntry{target_id: ^id, metadata: %{"topic" => "bug"}} = entry] =
               entries("accounts.support.viewed")

      refute inspect(entry) =~ "quiz"

      for bad <- [Ecto.UUID.generate(), "nope"] do
        assert call(:get, "/api/admin/support/requests/#{bad}", ctx.moderator)
               |> json_response(404)
      end
    end

    test "reply: e-mailed to the visitor without their text, status answered, audited", ctx do
      id = visitor_request!("visitor@example.test")
      assert_email_sent(subject: ~r/We received your request/)

      reply = "Thanks! The quiz accepted both spellings since this morning."

      assert %{"request" => %{"status" => "answered", "replies" => [r]}} =
               call(:post, "/api/admin/support/requests/#{id}/replies", ctx.moderator, %{
                 "body" => reply
               })
               |> json_response(201)

      assert %{"body" => ^reply, "email_status" => "sent", "author" => %{"id" => author}} = r
      assert author == ctx.moderator.id

      assert_email_sent(fn email ->
        assert email.to == [{"", "visitor@example.test"}]
        assert email.subject =~ "Reply to your request REQ-"
        assert email.text_body =~ reply
        refute email.text_body =~ "My quiz answer was refused"
        true
      end)

      assert [%AuditEntry{target_id: ^id, metadata: %{"length" => length}}] =
               entries("accounts.support.replied")

      assert length == String.length(reply)
      # a visitor has no account: no in-app notification
      assert all_enqueued(worker: NotifyWorker) == []

      assert %{"errors" => %{"body" => ["should be at least 2 character(s)"]}} =
               call(:post, "/api/admin/support/requests/#{id}/replies", ctx.moderator, %{
                 "body" => " x "
               })
               |> json_response(422)
    end

    test "reply to a member: their CURRENT account address, and an in-app notification", ctx do
      member = user_fixture(%{email: "first@example.test"})

      %{"request" => %{"id" => id}} = send_request(member, %{}) |> json_response(201)
      member |> Ecto.Changeset.change(email: "second@example.test") |> Repo.update!()

      call(:post, "/api/admin/support/requests/#{id}/replies", ctx.admin, %{"body" => "Fixed."})
      |> json_response(201)

      assert_email_sent(to: [{"", "first@example.test"}])
      assert_email_sent(to: [{"", "second@example.test"}], subject: ~r/Reply to your request/)

      assert [
               %{
                 "user_id" => user_id,
                 "category" => "account",
                 "kind" => "support_replied",
                 "params" => %{"request_id" => ^id},
                 "dedupe_key" => "support_reply:" <> _
               }
             ] = Enum.map(all_enqueued(worker: NotifyWorker), & &1.args)

      assert user_id == member.id

      # the member sees the reply, never the internal note nor the staff member
      call(:patch, "/api/admin/support/requests/#{id}", ctx.admin, %{"internal_note" => "VIP?"})

      assert %{"requests" => [own]} =
               call(:get, "/api/me/support/requests", member) |> json_response(200)

      assert %{"status" => "answered", "replies" => [%{"body" => "Fixed."} = reply]} = own
      refute Map.has_key?(own, "internal_note")
      refute Map.has_key?(reply, "author")
    end

    test "status and internal note: audited, closed requests take no reply until reopened", ctx do
      id = visitor_request!()
      path = "/api/admin/support/requests/#{id}"

      assert %{"request" => %{"status" => "closed", "closed_at" => closed_at}} =
               call(:patch, path, ctx.moderator, %{"status" => "closed"}) |> json_response(200)

      assert closed_at

      assert %{"error" => "closed"} =
               call(:post, path <> "/replies", ctx.moderator, %{"body" => "Hello"})
               |> json_response(409)

      assert %{"request" => %{"internal_note" => "Duplicate of REQ-1", "status" => "open"} = r} =
               call(:patch, path, ctx.moderator, %{
                 "status" => "open",
                 "internal_note" => "  Duplicate of REQ-1 "
               })
               |> json_response(200)

      assert r["closed_at"] == nil

      # nothing changes without a difference
      call(:patch, path, ctx.moderator, %{"status" => "open"}) |> json_response(200)

      assert [%{metadata: %{"from" => "open", "to" => "closed"}}, %{metadata: %{"to" => "open"}}] =
               Enum.sort_by(entries("accounts.support.status_changed"), & &1.id)

      assert [%AuditEntry{metadata: %{"length" => 18}} = note] =
               entries("accounts.support.note_updated")

      refute inspect(note.metadata) =~ "Duplicate"

      assert %{"errors" => %{"status" => ["is invalid"]}} =
               call(:patch, path, ctx.moderator, %{"status" => "deleted"}) |> json_response(422)

      assert %{"errors" => %{"internal_note" => ["must not contain control characters"]}} =
               call(:patch, path, ctx.moderator, %{"internal_note" => "a\u0000b"})
               |> json_response(422)
    end
  end

  describe "erasure by an admin" do
    test "admin only (403 for a moderator), audited without the text, then gone", ctx do
      id = visitor_request!("erase.me@example.test")
      path = "/api/admin/support/requests/#{id}"

      assert %{"error" => "forbidden"} = call(:delete, path, ctx.moderator) |> json_response(403)
      assert Repo.get(SupportRequest, id)

      assert call(:delete, path, ctx.admin) |> response(204)
      refute Repo.get(SupportRequest, id)

      assert [%AuditEntry{target_id: ^id, metadata: %{"reference" => "REQ-" <> _} = metadata}] =
               entries("accounts.support.deleted")

      refute inspect(metadata) =~ "quiz"
      assert call(:delete, path, ctx.admin) |> json_response(404)
    end
  end

  describe "personal data and retention" do
    test "the member's requests are in their export and deleted with the account" do
      member = user_fixture()
      %{"request" => %{"id" => id}} = send_request(member, %{}) |> json_response(201)
      staff = staff_fixture("moderator")
      {:ok, _, _} = Support.reply(staff, id, %{"body" => "On it."})

      assert [
               %{
                 "message" => @message,
                 "status" => "answered",
                 "replies" => [%{"body" => "On it."}],
                 "internal_note" => nil
               }
             ] = Support.export(member)

      visitor = visitor_request!()

      member
      |> Ecto.Changeset.change(deletion_scheduled_at: DateTime.add(DateTime.utc_now(:second), -1))
      |> Repo.update!()

      Req.Test.stub(MlShared.Client, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
      :ok = MlAccounts.Privacy.execute_deletion(member.id)

      refute Repo.get(SupportRequest, id)
      assert Repo.aggregate(where(SupportReply, request_id: ^id), :count) == 0
      # a visitor's request is not touched by someone else's deletion
      assert Repo.get(SupportRequest, visitor)
    end

    test "purge: 180 days after closing, 365 days without activity; open recent requests stay" do
      now = DateTime.utc_now(:second)
      old = DateTime.add(now, -181, :day)

      closed_old = visitor_request!("a@example.test")
      closed_recent = visitor_request!("b@example.test")
      idle = visitor_request!("c@example.test")
      fresh = visitor_request!("d@example.test")

      from(r in SupportRequest, where: r.id == ^closed_old)
      |> Repo.update_all(set: [status: "closed", closed_at: old])

      from(r in SupportRequest, where: r.id == ^closed_recent)
      |> Repo.update_all(set: [status: "closed", closed_at: DateTime.add(now, -10, :day)])

      from(r in SupportRequest, where: r.id == ^idle)
      |> Repo.update_all(set: [updated_at: DateTime.add(now, -366, :day)])

      assert Support.purge(now) == 2
      assert Repo.get(SupportRequest, closed_recent)
      assert Repo.get(SupportRequest, fresh)
      refute Repo.get(SupportRequest, closed_old)
      refute Repo.get(SupportRequest, idle)

      assert :ok = perform_job(MlAccounts.Support.PurgeWorker, %{})
    end
  end
end
