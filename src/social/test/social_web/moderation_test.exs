defmodule MlSocialWeb.ModerationTest do
  use MlSocialWeb.ConnCase, async: true
  alias MlSocial.{Message, Repo, Report}

  @moduletag :capture_log
  @sanction_id "5a9c1e0e-0000-4000-8000-000000000001"

  setup do
    a = uuid()
    b = uuid()
    staff = uuid()
    conversation = conversation_between(a, b)

    %{"message" => %{"id" => message_id}} =
      api(:post, "/api/conversations/#{conversation.id}/messages", b, %{body: "You are useless"})
      |> json_response(201)

    %{"id" => report_id} =
      api(:post, "/api/reports", a, %{
        target_type: "message",
        target_id: message_id,
        reason: "harassment",
        details: "Insults"
      })
      |> json_response(201)

    stub_accounts(roles: %{staff => "moderator"})

    %{
      a: a,
      b: b,
      staff: staff,
      conversation: conversation,
      message_id: message_id,
      report_id: report_id
    }
  end

  # Faux accounts : rôles, restrictions, journal d'audit (`audit: :down`), sanctions ; chaque appel est rapporté
  # au test sous la forme `{:accounts, method, path, body, sub du jeton}`.
  defp stub_accounts(opts) do
    test = self()
    roles = Keyword.get(opts, :roles, %{})
    restricted = Keyword.get(opts, :restricted, %{})
    down? = Keyword.get(opts, :down, false)

    Req.Test.stub(MlShared.Client, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      ["Bearer " <> token] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, %{"sub" => sub}} = MlShared.InternalToken.verify(token)
      send(test, {:accounts, conn.method, conn.request_path, body, sub})

      case {conn.method, conn.request_path} do
        {"GET", "/api/internal/users/" <> _} when down? ->
          Req.Test.transport_error(conn, :econnrefused)

        {"GET", "/api/internal/users/" <> id} ->
          Req.Test.json(conn, %{
            "user" => internal_user(id, Map.get(roles, id, "user"), restricted[id])
          })

        {"POST", "/api/internal/audit"} ->
          if opts[:audit] == :down,
            do: Req.Test.transport_error(conn, :econnrefused),
            else: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 7})

        {"POST", "/api/admin/users/" <> _} ->
          case opts[:sanctions] do
            :down ->
              Req.Test.transport_error(conn, :econnrefused)

            {status, response} ->
              conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)

            nil ->
              conn
              |> Plug.Conn.put_status(201)
              |> Req.Test.json(%{"sanction" => %{"id" => @sanction_id}, "replayed" => false})
          end

        _ ->
          fake_accounts(conn)
      end
    end)
  end

  defp report_path(ctx, suffix \\ ""), do: "/api/moderation/reports/#{ctx.report_id}#{suffix}"

  describe "access" do
    test "members get 403 on every moderation route; accounts down → 503, nothing served", ctx do
      routes = [
        {:get, "/api/moderation/reports", nil},
        {:get, report_path(ctx), nil},
        {:post, report_path(ctx, "/evidence"), %{reason: "Checking the reported insult"}},
        {:post, report_path(ctx, "/resolve"), %{action: "dismiss", reason: "No issue"}},
        {:get, "/api/admin/stats", nil}
      ]

      for {method, path, body} <- routes do
        assert %{"error" => "forbidden"} = api(method, path, ctx.a, body) |> json_response(403)
      end

      refute_received {:accounts, "POST", "/api/internal/audit", _, _}

      other_staff = uuid()
      stub_accounts(down: true)

      assert %{"error" => "roles_unavailable"} =
               api(:get, "/api/moderation/reports", other_staff) |> json_response(503)
    end

    test "no staff route reads conversations; staff can't open a conversation they're not in",
         ctx do
      paths =
        for %{path: path} <- MlSocialWeb.Router.__routes__(),
            String.starts_with?(path, ["/api/moderation", "/api/admin"]),
            do: path

      assert paths != []
      refute Enum.any?(paths, &(&1 =~ "conversation" or &1 =~ "message"))

      for path <- [
            "/api/conversations/#{ctx.conversation.id}",
            "/api/conversations/#{ctx.conversation.id}/messages"
          ] do
        assert api(:get, path, ctx.staff) |> json_response(404)
      end
    end
  end

  describe "queue and evidence" do
    test "the queue never contains the message text", ctx do
      body = api(:get, "/api/moderation/reports", ctx.staff) |> response(200)
      refute body =~ "useless"

      assert %{
               "entries" => [
                 %{
                   "id" => report_id,
                   "status" => "open",
                   "reporter" => %{"id" => reporter},
                   "reported_user" => %{"id" => reported},
                   "message" => %{"removed" => false}
                 }
               ]
             } = Jason.decode!(body)

      assert {report_id, reporter, reported} == {ctx.report_id, ctx.a, ctx.b}
      refute api(:get, report_path(ctx), ctx.staff) |> response(200) =~ "useless"
    end

    test "evidence only with a reason of 10+ characters, audited BEFORE it is returned", ctx do
      assert %{"errors" => %{"reason" => _}} =
               api(:post, report_path(ctx, "/evidence"), ctx.staff, %{reason: "check"})
               |> json_response(422)

      refute_received {:accounts, "POST", "/api/internal/audit", _, _}

      assert %{"evidence" => %{"body" => "You are useless", "sender" => %{"id" => sender}}} =
               api(:post, report_path(ctx, "/evidence"), ctx.staff, %{
                 reason: "Harassment report review"
               })
               |> json_response(200)

      assert sender == ctx.b

      assert_received {:accounts, "POST", "/api/internal/audit",
                       %{
                         "actor_id" => actor,
                         "action" => "social.report.evidence_viewed",
                         "reason" => "Harassment report review",
                         "metadata" => metadata
                       }, nil}

      assert actor == ctx.staff
      refute inspect(metadata) =~ "useless"

      # the audit log can't be written: no evidence at all
      stub_accounts(roles: %{ctx.staff => "moderator"}, audit: :down)

      assert %{"error" => "audit_unavailable"} =
               body =
               api(:post, report_path(ctx, "/evidence"), ctx.staff, %{
                 reason: "Harassment report review"
               })
               |> json_response(503)

      refute inspect(body) =~ "useless"
    end

    test "a member report has no message evidence", ctx do
      %{"id" => id} =
        api(:post, "/api/reports", ctx.a, %{target_type: "user", target_id: ctx.b, reason: "spam"})
        |> json_response(201)

      assert %{"error" => "no_evidence"} =
               api(:post, "/api/moderation/reports/#{id}/evidence", ctx.staff, %{
                 reason: "Looking for a message"
               })
               |> json_response(409)
    end
  end

  describe "resolution" do
    test "remove_message: logical removal shown to participants, every open report settled",
         ctx do
      %{"id" => second} =
        api(:post, "/api/reports", ctx.a, %{
          target_type: "message",
          target_id: ctx.message_id,
          reason: "inappropriate"
        })
        |> json_response(201)

      # livraison par membre : chaque participant reçoit le retrait sur son topic
      MlShared.Events.subscribe("user:#{ctx.a}")

      assert %{"errors" => %{"reason" => _}} =
               api(:post, report_path(ctx, "/resolve"), ctx.staff, %{action: "remove_message"})
               |> json_response(422)

      assert %{"report" => %{"status" => "resolved", "message" => %{"removed" => true}}} =
               api(:post, report_path(ctx, "/resolve"), ctx.staff, %{
                 action: "remove_message",
                 reason: "Insulting another member"
               })
               |> json_response(200)

      message_id = ctx.message_id

      assert_receive {:message_removed, %{"id" => ^message_id, "removed" => true, "body" => nil}}

      for member <- [ctx.a, ctx.b] do
        assert %{"entries" => [%{"id" => ^message_id, "removed" => true, "body" => nil}]} =
                 api(:get, "/api/conversations/#{ctx.conversation.id}/messages", member)
                 |> json_response(200)
      end

      # logical: the text is kept for appeals, the second report is settled too
      assert %Message{body: "You are useless", removed_by: by} = Repo.get!(Message, message_id)
      assert by == ctx.staff
      assert %Report{status: "resolved", resolution: "remove_message"} = Repo.get!(Report, second)

      assert_received {:accounts, "POST", "/api/internal/audit",
                       %{"action" => "social.report.resolved", "metadata" => meta}, nil}

      assert meta["action"] == "remove_message"

      assert %{"error" => "already_resolved"} =
               api(:post, report_path(ctx, "/resolve"), ctx.staff, %{
                 action: "dismiss",
                 reason: "Second thoughts"
               })
               |> json_response(409)
    end

    test "restrict: sanction posted at accounts as the staff member, idempotent ref", ctx do
      assert %{"errors" => %{"duration_hours" => _}} =
               api(:post, report_path(ctx, "/resolve"), ctx.staff, %{
                 action: "restrict",
                 reason: "Repeated insults"
               })
               |> json_response(422)

      assert %{
               "report" => %{
                 "resolution" => %{"action" => "restrict", "sanction_id" => @sanction_id}
               }
             } =
               api(:post, report_path(ctx, "/resolve"), ctx.staff, %{
                 action: "restrict",
                 reason: "Repeated insults",
                 duration_hours: 24
               })
               |> json_response(200)

      target_path = "/api/admin/users/#{ctx.b}/sanctions"
      ref = "social:report:#{ctx.report_id}"

      assert_received {:accounts, "POST", ^target_path,
                       %{"kind" => "restriction", "duration_hours" => 24, "ref" => ^ref}, sub}

      assert sub == ctx.staff
    end

    test "accounts unreachable for the sanction: the report stays open", ctx do
      stub_accounts(roles: %{ctx.staff => "moderator"}, sanctions: :down)

      assert %{"error" => "accounts_unavailable"} =
               api(:post, report_path(ctx, "/resolve"), ctx.staff, %{
                 action: "warn",
                 reason: "Be respectful"
               })
               |> json_response(503)

      assert %Report{status: "open"} = Repo.get!(Report, ctx.report_id)

      stub_accounts(
        roles: %{ctx.staff => "moderator"},
        sanctions: {409, %{"error" => "staff_target"}}
      )

      assert %{"error" => "staff_target"} =
               api(:post, report_path(ctx, "/resolve"), ctx.staff, %{
                 action: "warn",
                 reason: "Be respectful"
               })
               |> json_response(409)
    end

    test "remove_message makes no sense for a member report", ctx do
      %{"id" => id} =
        api(:post, "/api/reports", ctx.a, %{target_type: "user", target_id: ctx.b, reason: "spam"})
        |> json_response(201)

      assert %{"errors" => %{"action" => _}} =
               api(:post, "/api/moderation/reports/#{id}/resolve", ctx.staff, %{
                 action: "remove_message",
                 reason: "Spam profile"
               })
               |> json_response(422)
    end
  end

  describe "restrictions" do
    test "a restricted member can't send messages until the end date", ctx do
      until = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      iso = DateTime.to_iso8601(until)
      stub_accounts(restricted: %{ctx.a => iso})

      assert %{"error" => "restricted", "restricted_until" => ^iso} =
               api(:post, "/api/conversations/#{ctx.conversation.id}/messages", ctx.a, %{
                 body: "hello?"
               })
               |> json_response(403)

      # an expired restriction no longer applies (a member whose status isn't cached yet)
      fresh = uuid()
      conversation = conversation_between(fresh, ctx.a)
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      stub_accounts(restricted: %{fresh => past})

      assert api(:post, "/api/conversations/#{conversation.id}/messages", fresh, %{body: "sorry"})
             |> json_response(201)
    end

    test "accounts unreachable: sending is refused, never allowed by default" do
      stranger = uuid()
      other = uuid()
      conversation = conversation_between(stranger, other)
      stub_accounts(down: true)

      assert %{"error" => "accounts_unavailable"} =
               api(:post, "/api/conversations/#{conversation.id}/messages", stranger, %{
                 body: "hi"
               })
               |> json_response(503)
    end

    test "invalidation: a sanction change clears the cached status at once", ctx do
      assert api(:post, "/api/conversations/#{ctx.conversation.id}/messages", ctx.a, %{body: "1"})
             |> json_response(201)

      iso = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      stub_accounts(restricted: %{ctx.a => iso})
      # cached for 10 s, unless accounts announces the change
      MlShared.Events.broadcast("members", {:sanction_changed, ctx.a})
      :sys.get_state(MlSocial.Cache)

      assert %{"error" => "restricted"} =
               api(:post, "/api/conversations/#{ctx.conversation.id}/messages", ctx.a, %{
                 body: "2"
               })
               |> json_response(403)
    end
  end

  test "stats are real counts", ctx do
    assert %{"stats" => %{"messages_7d" => messages, "open_reports" => open}} =
             api(:get, "/api/admin/stats", ctx.staff) |> json_response(200)

    assert messages >= 1 and open >= 1
  end

  describe "pièce jointe du message signalé" do
    setup ctx do
      %{"message" => %{"id" => message_id, "attachment" => %{"id" => attachment_id}}} =
        api(:post, "/api/conversations/#{ctx.conversation.id}/messages", ctx.b, %{
          body: "Look at this",
          attachment: attachment(MlShared.ImageFixtures.png(32, 32), "insult.png")
        })
        |> json_response(201)

      %{"id" => report_id} =
        api(:post, "/api/reports", ctx.a, %{
          target_type: "message",
          target_id: message_id,
          reason: "inappropriate"
        })
        |> json_response(201)

      %{image_report: report_id, image_message: message_id, attachment_id: attachment_id}
    end

    defp open_attachment(ctx, user, reason),
      do:
        api(:post, "/api/moderation/reports/#{ctx.image_report}/attachment", user, %{
          reason: reason
        })

    test "métadonnées dans la preuve ; contenu seulement avec un motif, audité AVANT d'être renvoyé",
         ctx do
      assert %{"evidence" => %{"attachment" => meta}} =
               api(:post, "/api/moderation/reports/#{ctx.image_report}/evidence", ctx.staff, %{
                 reason: "Checking the reported picture"
               })
               |> json_response(200)

      assert %{"kind" => "image", "filename" => "insult.png", "content_type" => "image/png"} =
               meta

      assert %{"errors" => %{"reason" => _}} =
               open_attachment(ctx, ctx.staff, "short") |> json_response(422)

      refute_received {:accounts, "POST", "/api/internal/audit",
                       %{"action" => "social.report.attachment_viewed"}, _}

      assert %{"error" => "forbidden"} =
               open_attachment(ctx, ctx.a, "I am not staff at all") |> json_response(403)

      conn = open_attachment(ctx, ctx.staff, "Reviewing the reported image")
      assert <<0x89, "PNG", _::binary>> = response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]

      assert_received {:accounts, "POST", "/api/internal/audit",
                       %{
                         "action" => "social.report.attachment_viewed",
                         "reason" => "Reviewing the reported image",
                         "metadata" => %{"attachment_id" => attachment_id, "kind" => "image"}
                       }, nil}

      assert attachment_id == ctx.attachment_id

      stub_accounts(roles: %{ctx.staff => "moderator"}, audit: :down)

      assert %{"error" => "audit_unavailable"} =
               open_attachment(ctx, ctx.staff, "Reviewing the reported image")
               |> json_response(503)
    end

    test "message retiré : pièce jointe inaccessible aux membres, preuve auditée encore possible",
         ctx do
      assert api(:get, "/api/attachments/#{ctx.attachment_id}", ctx.a) |> response(200)

      api(:post, "/api/moderation/reports/#{ctx.image_report}/resolve", ctx.staff, %{
        action: "remove_message",
        reason: "Inappropriate picture"
      })
      |> json_response(200)

      for member <- [ctx.a, ctx.b] do
        assert api(:get, "/api/attachments/#{ctx.attachment_id}", member) |> json_response(404)
      end

      assert %{"entries" => entries} =
               api(:get, "/api/conversations/#{ctx.conversation.id}/messages", ctx.a)
               |> json_response(200)

      assert %{"removed" => true, "attachment" => nil, "body" => nil} =
               Enum.find(entries, &(&1["id"] == ctx.image_message))

      assert open_attachment(ctx, ctx.staff, "Appeal review of the picture") |> response(200)
    end

    test "signalement d'un message sans pièce jointe : 409 no_attachment", ctx do
      assert %{"error" => "no_attachment"} =
               api(:post, "/api/moderation/reports/#{ctx.report_id}/attachment", ctx.staff, %{
                 reason: "Is there any picture here?"
               })
               |> json_response(409)
    end
  end
end
