defmodule MysticWeb.Admin.MemberSideTest do
  @moduledoc "What the member sees: their sanctions and appeal, removed messages, reporting a message, restriction errors."
  use MysticWeb.ConnCase, async: true

  describe "/account/sanctions" do
    setup do
      sanction = %{
        "id" => "s1",
        "kind" => "restriction",
        "reason" => "Spamming links",
        "status" => "active",
        "ends_at" => "2026-11-24T10:00:00Z",
        "inserted_at" => "2026-11-23T10:00:00Z",
        "lifted_at" => nil,
        "lift_reason" => nil,
        "appealable" => true,
        "appeal" => nil
      }

      %{user: user_fixture(), sanction: sanction}
    end

    test "lists the sanctions and sends a reasoned appeal", %{conn: conn, user: user, sanction: s} do
      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/sanctions"} => %{"sanctions" => [s]},
          {"POST", "/api/me/sanctions/s1/appeal"} => fn _conn, %{"body" => body} ->
            if String.length(body) < 10,
              do:
                {422,
                 %{
                   "error" => "invalid",
                   "errors" => %{"body" => ["should be at least 10 character(s)"]}
                 }},
              else: {201, %{"appeal" => %{"id" => "a1", "status" => "open"}}}
          end
        })
      )

      {:ok, view, _} = conn |> log_in() |> live(~p"/account/sanctions")
      assert has_element?(view, "#sanction-s1", "Spamming links")
      assert has_element?(view, "#sanction-s1", "can't send private messages")

      view |> element("#appeal-button-s1") |> render_click()
      view |> form("#appeal-form", appeal: %{body: "short"}) |> render_submit()
      assert has_element?(view, "#appeal-form", "at least 10")

      view
      |> form("#appeal-form", appeal: %{body: "Those links were course resources."})
      |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/me/sanctions/s1/appeal",
                         body: %{"body" => "Those links were course resources."}
                       }}

      assert render(view) =~ "Appeal sent"
    end

    test "reloads on {:sanction_changed, _}", %{conn: conn, user: user, sanction: s} do
      stub_api(
        Map.merge(member_routes(user), %{{"GET", "/api/me/sanctions"} => %{"sanctions" => []}})
      )

      {:ok, view, _} = conn |> log_in() |> live(~p"/account/sanctions")
      assert has_element?(view, "#sanctions-empty")

      stub_api(
        Map.merge(member_routes(user), %{{"GET", "/api/me/sanctions"} => %{"sanctions" => [s]}})
      )

      send(view.pid, {:sanction_changed, user["id"]})
      assert has_element?(view, "#sanction-s1")
    end
  end

  describe "messages" do
    setup do
      user = user_fixture()
      hugo = member_fixture()
      cid = uuid()

      removed =
        %{message("m2", cid, hugo["id"], nil) | "body" => nil} |> Map.put("removed", true)

      conversation = direct_conversation(cid, user, hugo, %{"last_message" => removed})

      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/conversations"} => %{"conversations" => [conversation]},
          {"GET", "/api/conversations/#{cid}"} => %{"conversation" => conversation},
          {"GET", "/api/conversations/#{cid}/messages"} => %{
            "entries" => [
              Map.put(message("m1", cid, hugo["id"], "Hello Léa!"), "removed", false),
              removed
            ],
            "next_before" => nil
          },
          {"POST", "/api/conversations/#{cid}/read"} => {204, nil},
          {"GET", "/api/me/friends"} => %{"friends" => [hugo]},
          {"POST", "/api/reports"} => {201, %{"id" => "r1"}},
          {"POST", "/api/conversations/#{cid}/messages"} =>
            {403, %{"error" => "restricted", "restricted_until" => "2026-11-24T10:00:00Z"}}
        })

      %{routes: routes, cid: cid, hugo: hugo}
    end

    test "a removed message keeps its place, shown as removed by moderation, also live", ctx do
      stub_api(ctx.routes)
      {:ok, view, _} = ctx.conn |> log_in() |> live(~p"/messages/#{ctx.cid}")
      assert has_element?(view, "#message-m2", "Message removed by moderation")
      assert has_element?(view, "#conversation-#{ctx.cid}", "Message removed by moderation")
      refute has_element?(view, "#report-m2")

      removed_m1 =
        message("m1", ctx.cid, ctx.hugo["id"], nil) |> Map.merge(%{"removed" => true})

      send(view.pid, {:message_removed, removed_m1})
      assert has_element?(view, "#message-m1", "Message removed by moderation")
      refute has_element?(view, "#message-m1", "Hello Léa!")
    end

    test "the other participant's message can be reported (message snapshot kept by social)",
         ctx do
      stub_api(ctx.routes)
      {:ok, view, _} = ctx.conn |> log_in() |> live(~p"/messages/#{ctx.cid}")

      view |> element("#report-m1") |> render_click()

      view
      |> form("#report-form", report: %{reason: "harassment", details: "Rude"})
      |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/reports",
                         body: %{
                           "target_type" => "message",
                           "target_id" => "m1",
                           "reason" => "harassment"
                         }
                       }}

      assert render(view) =~ "Report sent"
    end

    test "a restricted member's send is refused with the end date", ctx do
      stub_api(ctx.routes)
      {:ok, view, _} = ctx.conn |> log_in() |> live(~p"/messages/#{ctx.cid}")
      view |> form("#composer", message: %{body: "Hello?"}) |> render_submit()
      assert has_element?(view, "#composer-locked", "Your account is restricted until")
    end
  end
end
