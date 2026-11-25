defmodule MlCommunityWeb.AdminTest do
  @moduledoc "Restrictions posées par le staff, audit central des actions de modération, routes staff ajoutées."
  use MlCommunityWeb.ConnCase, async: true
  alias MlCommunity.{Discussion, ModerationEntry, Repo}

  setup do
    {author, member, staff} = {uuid(), uuid(), uuid()}
    stub_services(staff: [staff])
    d = discussion!(author)
    {:ok, author: author, member: member, staff: staff, discussion: d}
  end

  defp future, do: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

  describe "restrictions" do
    test "a restricted member can't open a discussion, reply or edit (403 + end date)", ctx do
      restricted = uuid()
      until = DateTime.to_iso8601(future())
      stub_services(restricted: %{restricted => until})

      new = %{
        "category" => "help-questions",
        "title" => "How do loops end?",
        "body" => "A body long enough to be valid."
      }

      assert %{"error" => "restricted", "restricted_until" => ^until} =
               api(:post, "/api/discussions", restricted, new) |> json_response(403)

      assert %{"error" => "restricted"} =
               api(:post, "/api/discussions/#{ctx.discussion.slug}/replies", restricted, %{
                 "body" => "Me too!"
               })
               |> json_response(403)

      # reading is not affected
      assert %{"discussion" => _} =
               api(:get, "/api/discussions/#{ctx.discussion.slug}", restricted)
               |> json_response(200)

      # an expired restriction no longer applies
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      stub_services(restricted: %{ctx.member => past})

      assert %{"reply" => _} =
               api(:post, "/api/discussions/#{ctx.discussion.slug}/replies", ctx.member, %{
                 "body" => "It stops at the limit."
               })
               |> json_response(201)
    end

    test "editing is publishing too", %{author: author, discussion: d} do
      stub_services(restricted: %{author => DateTime.to_iso8601(future())})

      assert %{"error" => "restricted"} =
               api(:patch, "/api/discussions/#{d.slug}", author, %{"title" => "New title here"})
               |> json_response(403)
    end

    @tag :capture_log
    test "accounts unreachable: posting refused (503), reading still works", ctx do
      someone = uuid()
      stub_services(down: ["accounts"])

      assert %{"error" => "roles_unavailable"} =
               api(:post, "/api/discussions/#{ctx.discussion.slug}/replies", someone, %{
                 "body" => "Hello there"
               })
               |> json_response(503)

      assert %{"entries" => [_ | _]} =
               api(:get, "/api/discussions", someone) |> json_response(200)
    end
  end

  describe "central audit" do
    test "each moderation action is written to the central audit log", ctx do
      assert api(:post, "/api/moderation/discussions/#{ctx.discussion.id}", ctx.staff, %{
               "action" => "hide",
               "reason" => "Off-topic"
             })
             |> response(204)

      assert_received {:audit,
                       %{
                         "action" => "community.discussion.hide",
                         "actor_id" => actor,
                         "target_id" => target,
                         "reason" => "Off-topic",
                         "metadata" => %{"from" => "visible", "to" => "hidden"}
                       }}

      assert {actor, target} == {ctx.staff, ctx.discussion.id}
    end

    @tag :capture_log
    test "audit log unreachable: the action is rolled back (503)", ctx do
      stub_services(staff: [ctx.staff], audit: :down)

      assert %{"error" => "audit_unavailable"} =
               api(:post, "/api/moderation/discussions/#{ctx.discussion.id}", ctx.staff, %{
                 "action" => "remove",
                 "reason" => "Spam"
               })
               |> json_response(503)

      assert Repo.get!(Discussion, ctx.discussion.id).status == "visible"
      assert Repo.aggregate(ModerationEntry, :count) == 0
    end

    test "report detail and resolution are audited", ctx do
      %{"id" => report_id} =
        api(:post, "/api/reports", ctx.member, %{
          "target_type" => "discussion",
          "target_id" => ctx.discussion.id,
          "reason" => "spam"
        })
        |> json_response(201)

      assert %{
               "report" => %{"id" => ^report_id, "status" => "open", "snapshot" => %{"body" => _}}
             } =
               api(:get, "/api/moderation/reports/#{report_id}", ctx.staff) |> json_response(200)

      assert api(:get, "/api/moderation/reports/#{report_id}", ctx.member) |> json_response(403)
      assert api(:get, "/api/moderation/reports/#{uuid()}", ctx.staff) |> json_response(404)

      assert %{"report" => %{"status" => "resolved"}} =
               api(:post, "/api/moderation/reports/#{report_id}/resolve", ctx.staff, %{
                 "action" => "dismiss",
                 "reason" => "Not spam"
               })
               |> json_response(200)

      assert_received {:audit, %{"action" => "community.report.resolved", "metadata" => meta}}
      assert meta == %{"action" => "dismiss"}
    end
  end

  test "stats: staff only, real counts", ctx do
    assert api(:get, "/api/admin/stats", ctx.member) |> json_response(403)

    assert %{"stats" => %{"discussions_7d" => d, "replies_7d" => 0, "open_reports" => 0}} =
             api(:get, "/api/admin/stats", ctx.staff) |> json_response(200)

    assert d >= 1
  end
end
