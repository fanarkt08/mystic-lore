defmodule MlCommunityWeb.ModerationControllerTest do
  use MlCommunityWeb.ConnCase, async: true
  import Ecto.Query
  alias MlCommunity.{Discussion, ModerationEntry, Reply, Report, Repo}

  setup do
    {author, member, staff} = {uuid(), uuid(), uuid()}
    stub_services(staff: [staff])
    d = discussion!(author)
    {:ok, author: author, member: member, staff: staff, discussion: d, reply: reply!(member, d)}
  end

  defp moderate(user, %Discussion{id: id}, body),
    do: api(:post, "/api/moderation/discussions/#{id}", user, body)

  defp moderate(user, %Reply{id: id}, body),
    do: api(:post, "/api/moderation/replies/#{id}", user, body)

  defp log(target_id),
    do:
      Repo.all(
        from e in ModerationEntry, where: e.target_id == ^target_id, order_by: e.inserted_at
      )

  describe "staff rights (role read from accounts, never from the request)" do
    test "a member is refused, even with a forged role in the body or headers", %{
      member: member,
      discussion: d
    } do
      forged = %{
        "action" => "hide",
        "reason" => "Because",
        "role" => "admin",
        "user" => %{"role" => "moderator"}
      }

      assert %{"error" => "forbidden"} = moderate(member, d, forged) |> json_response(403)

      conn =
        build_conn()
        |> put_req_header(
          "authorization",
          "Bearer " <> MlShared.InternalToken.sign("web", member)
        )
        |> put_req_header("x-ml-role", "admin")
        |> put_req_header("content-type", "application/json")
        |> dispatch(
          @endpoint,
          :post,
          "/api/moderation/discussions/#{d.id}",
          Jason.encode!(forged)
        )

      assert %{"error" => "forbidden"} = json_response(conn, 403)

      assert %{"error" => "forbidden"} =
               api(:get, "/api/moderation/reports", member) |> json_response(403)

      assert Repo.get!(Discussion, d.id).status == "visible"
      assert log(d.id) == []
    end

    @tag :capture_log
    test "accounts unreachable: 503 roles_unavailable, nothing changes", %{discussion: d} do
      someone = uuid()
      stub_services(down: ["accounts"])

      assert %{"error" => "roles_unavailable"} =
               moderate(someone, d, %{"action" => "lock"}) |> json_response(503)

      refute Repo.get!(Discussion, d.id).locked
    end
  end

  describe "actions" do
    test "hide and remove need a reason; restore; every action is logged", %{
      staff: staff,
      discussion: d,
      reply: r
    } do
      assert %{"errors" => %{"reason" => ["can't be blank"]}} =
               moderate(staff, d, %{"action" => "hide", "reason" => "  "}) |> json_response(422)

      assert response(
               moderate(staff, d, %{"action" => "hide", "reason" => "Off-topic flame war"}),
               204
             )

      assert %Discussion{status: "hidden", moderation_reason: "Off-topic flame war"} =
               Repo.get!(Discussion, d.id)

      assert response(
               moderate(staff, r, %{"action" => "remove", "reason" => "Personal attack"}),
               204
             )

      assert Repo.get!(Reply, r.id).status == "removed"

      assert response(moderate(staff, d, %{"action" => "restore"}), 204)
      assert %Discussion{status: "visible", moderation_reason: nil} = Repo.get!(Discussion, d.id)
      # on ne restaure que ce qui est masqué ou retiré
      assert %{"error" => "conflict"} =
               moderate(staff, d, %{"action" => "restore"}) |> json_response(409)

      assert [
               %{
                 action: "hide",
                 reason: "Off-topic flame war",
                 moderator_id: ^staff,
                 metadata: %{"from" => "visible", "to" => "hidden"}
               },
               %{action: "restore", metadata: %{"from" => "hidden", "to" => "visible"}}
             ] = log(d.id)

      assert [%{action: "remove", reason: "Personal attack", target_type: "reply"}] = log(r.id)
    end

    test "lock, pin and move a discussion", %{staff: staff, discussion: d} do
      for action <- ~w(lock pin),
          do: assert(response(moderate(staff, d, %{"action" => action}), 204))

      assert %Discussion{locked: true, pinned: true} = Repo.get!(Discussion, d.id)

      assert %{"errors" => %{"category" => ["is invalid"]}} =
               moderate(staff, d, %{"action" => "move", "category" => "dark-arts"})
               |> json_response(422)

      assert response(
               moderate(staff, d, %{"action" => "move", "category" => "study-groups"}),
               204
             )

      assert Repo.get!(Discussion, d.id).category == "study-groups"

      for action <- ~w(unlock unpin),
          do: assert(response(moderate(staff, d, %{"action" => action}), 204))

      assert %Discussion{locked: false, pinned: false} = Repo.get!(Discussion, d.id)

      assert Enum.map(log(d.id), & &1.action) == ~w(lock pin move unlock unpin)

      assert %{metadata: %{"from" => "help-questions", "to" => "study-groups"}} =
               Enum.at(log(d.id), 2)
    end

    test "invalid actions, unknown targets, content deleted by its author", %{
      author: author,
      staff: staff,
      discussion: d,
      reply: r
    } do
      assert %{"errors" => %{"action" => ["is invalid"]}} =
               moderate(staff, r, %{"action" => "pin"}) |> json_response(422)

      assert api(:post, "/api/moderation/discussions/#{uuid()}", staff, %{"action" => "lock"})
             |> json_response(404)

      assert api(:post, "/api/moderation/replies/nope", staff, %{"action" => "restore"})
             |> json_response(404)

      :ok = MlCommunity.Posts.delete_discussion(viewer(author), d.slug)

      assert %{"error" => "conflict"} =
               moderate(staff, d, %{"action" => "hide", "reason" => "Too late"})
               |> json_response(409)

      assert Repo.get!(Discussion, d.id).status == "deleted"
    end

    test "hiding the solution reply unmarks the discussion as solved", %{
      author: author,
      staff: staff,
      discussion: d,
      reply: r
    } do
      {:ok, _} = MlCommunity.Posts.set_solution(viewer(author), d.slug, r.id)

      assert response(
               moderate(staff, r, %{"action" => "hide", "reason" => "Wrong and rude"}),
               204
             )

      assert Repo.get!(Discussion, d.id).solution_reply_id == nil
    end
  end

  describe "reports queue" do
    setup %{author: author, member: member, discussion: d, reply: r} do
      {:ok, on_reply} =
        MlCommunity.Reports.create(viewer(author), %{
          "target_type" => "reply",
          "target_id" => r.id,
          "reason" => "spam"
        })

      {:ok, on_discussion} =
        MlCommunity.Reports.create(viewer(member), %{
          "target_type" => "discussion",
          "target_id" => d.id,
          "reason" => "other",
          "details" => "Duplicate topic"
        })

      {:ok, again_on_reply} =
        MlCommunity.Reports.create(viewer(uuid()), %{
          "target_type" => "reply",
          "target_id" => r.id,
          "reason" => "harassment"
        })

      %{reports: [on_reply, on_discussion, again_on_reply]}
    end

    test "open reports, oldest first, with snapshot, people and current target status", %{
      author: author,
      member: member,
      staff: staff,
      reply: r,
      reports: [first | _]
    } do
      %{"entries" => entries, "total" => 3, "page" => 1, "total_pages" => 1} =
        api(:get, "/api/moderation/reports", staff) |> json_response(200)

      assert [report | _] = entries
      assert report["id"] == first.id

      assert %{
               "target_type" => "reply",
               "target_id" => target,
               "target_status" => "visible",
               "reason" => "spam",
               "status" => "open",
               "resolution" => nil,
               "reporter" => %{"id" => ^author, "display_name" => "User " <> _},
               "snapshot" => %{"body" => body, "author" => %{"id" => ^member}, "title" => title}
             } = report

      assert target == r.id and body == r.body and title == "Why does range(3) stop at 2?"
    end

    test "resolve: dismiss closes one report; hide moderates the target and closes its reports",
         %{
           staff: staff,
           reply: r,
           reports: [on_reply, on_discussion, again_on_reply]
         } do
      resolve = fn report, body ->
        api(:post, "/api/moderation/reports/#{report.id}/resolve", staff, body)
      end

      assert %{"errors" => %{"action" => ["is invalid"]}} =
               resolve.(on_discussion, %{"action" => "ban"}) |> json_response(422)

      assert %{"errors" => %{"reason" => ["can't be blank"]}} =
               resolve.(on_reply, %{"action" => "hide"}) |> json_response(422)

      assert %{
               "report" => %{
                 "status" => "resolved",
                 "resolution" => %{"action" => "dismiss", "moderator_id" => ^staff}
               }
             } =
               resolve.(on_discussion, %{"action" => "dismiss"}) |> json_response(200)

      assert %{"error" => "already_resolved"} =
               resolve.(on_discussion, %{"action" => "dismiss"}) |> json_response(409)

      assert %{
               "report" => %{
                 "target_status" => "hidden",
                 "resolution" => %{"reason" => "Advertising"}
               }
             } =
               resolve.(on_reply, %{"action" => "hide", "reason" => "Advertising"})
               |> json_response(200)

      assert Repo.get!(Reply, r.id).status == "hidden"
      # l'autre signalement ouvert sur la même réponse est réglé du même coup
      assert %Report{status: "resolved", resolution: "hide"} =
               Repo.get!(Report, again_on_reply.id)

      assert %{"entries" => [], "total" => 0} =
               api(:get, "/api/moderation/reports", staff) |> json_response(200)

      assert ["hide"] = Enum.map(log(r.id), & &1.action)

      assert [%{action: "resolve_report", target_type: "report", metadata: %{"action" => "hide"}}] =
               log(on_reply.id)

      assert Repo.aggregate(where(ModerationEntry, action: "resolve_report"), :count) == 2
      assert resolve.(%{id: uuid()}, %{"action" => "dismiss"}) |> json_response(404)
    end
  end
end
