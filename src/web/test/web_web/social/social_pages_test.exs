defmodule MysticWeb.Social.PagesTest do
  @moduledoc """
  Social features outside /messages: friends (online dots, group shortcut, permission refusals), the Privacy
  section of the settings (held by social), the attachment relay and the staff's audited attachment download.
  """
  use MysticWeb.ConnCase, async: true
  import MysticWeb.AdminFixtures

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "image body">>
  @pdf "%PDF-1.4\nfake document"

  defp settings(attrs \\ %{}) do
    Map.merge(
      %{
        "show_online" => true,
        "read_receipts" => true,
        "friend_requests" => "everyone",
        "group_adds" => "friends",
        "lobby_invites" => "friends"
      },
      attrs
    )
  end

  describe "/friends" do
    setup do
      user = user_fixture()
      hugo = member_fixture()
      ines = member_fixture(%{"username" => "ines_petit", "display_name" => "Inès Petit"})

      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/friends"} => %{
            "friends" => [
              Map.put(hugo, "online_visible", true),
              Map.put(ines, "online_visible", false)
            ]
          },
          {"GET", "/api/me/friend-requests"} => %{"incoming" => [], "outgoing" => []},
          {"GET", "/api/me/blocks"} => %{"blocks" => []}
        })

      %{user: user, hugo: hugo, ines: ines, routes: routes}
    end

    test "online dot only for a connected friend who allows it; it follows the setting", ctx do
      stub_api(ctx.routes)
      {:ok, view, _} = ctx.conn |> log_in() |> live(~p"/friends")
      assert has_element?(view, "a#friends-new-group[href='/messages/new']")

      # a connected page of Hugo and one of Inès
      pages =
        for id <- [ctx.hugo["id"], ctx.ines["id"]] do
          pid = spawn(fn -> Process.sleep(:infinity) end)
          {:ok, _} = MysticWeb.Presence.track_member(pid, id)
          pid
        end

      assert eventually(fn ->
               has_element?(view, "#friend-#{ctx.hugo["id"]} .presence-dot", "Online")
             end)

      refute has_element?(view, "#friend-#{ctx.ines["id"]} .presence-dot")

      # Hugo hides his status: social tells his friends (friendship_changed), the dot disappears at once
      stub_api(%{
        ctx.routes
        | {"GET", "/api/me/friends"} => %{
            "friends" => [
              Map.put(ctx.hugo, "online_visible", false),
              Map.put(ctx.ines, "online_visible", false)
            ]
          }
      })

      MlShared.Events.broadcast("user:#{ctx.user["id"]}", {:friendship_changed, ctx.user["id"]})

      assert eventually(fn ->
               not has_element?(view, "#friend-#{ctx.hugo["id"]} .presence-dot")
             end)

      Enum.each(pages, &Process.exit(&1, :kill))
    end

    test "a friend request refused by the member's permission is explained (403 from social)",
         ctx do
      clara = member_fixture(%{"username" => "clara_dubois", "display_name" => "Clara Dubois"})

      stub_api(
        Map.merge(ctx.routes, %{
          {"GET", "/api/users/search"} => %{"users" => [clara]},
          {"POST", "/api/friend-requests"} => {403, %{"error" => "friend_requests_closed"}}
        })
      )

      {:ok, view, _} = ctx.conn |> log_in() |> live(~p"/friends")
      view |> form("#member-search", %{q: "clara"}) |> render_change()
      view |> element("#result-#{clara["id"]} button", "Add friend") |> render_click()
      assert render(view) =~ "This member doesn&#39;t accept friend requests from you."
    end

    test "an activity invitation refused the same way has its own message" do
      assert MysticWeb.MultiplayerComponents.error_text(
               {:error, {:http, 403, %{"error" => "lobby_invites_closed"}}}
             ) == "This member doesn't accept activity invitations."
    end
  end

  describe "/settings/privacy" do
    setup do
      user =
        user_fixture(%{
          "preferences" => %{"language" => "auto", "time_zone" => "auto", "theme" => "system"}
        })

      %{user: user}
    end

    defp open(conn, user, routes) do
      stub_api(Map.merge(member_routes(user), routes))
      {:ok, view, _} = conn |> log_in() |> live(~p"/settings/privacy")
      view
    end

    test "loaded from social; saves announced only once social confirmed them", ctx do
      view =
        open(ctx.conn, ctx.user, %{
          {"GET", "/api/me/settings"} => %{"settings" => settings()},
          {"PATCH", "/api/me/settings"} => fn _conn, body -> %{"settings" => settings(body)} end
        })

      assert has_element?(view, "#settings-nav-privacy[aria-current=page]")
      assert has_element?(view, "#privacy-show-online[checked]")
      assert has_element?(view, "#privacy-friend-requests-everyone[checked]")
      assert has_element?(view, "#presence-status[aria-live=polite]")
      refute has_element?(view, "#presence-status span")

      view
      |> form("#presence-form", presence: %{show_online: "false", read_receipts: "true"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         path: "/api/me/settings",
                         body: %{"show_online" => false, "read_receipts" => true}
                       }}

      assert has_element?(view, "#presence-status", "Visibility saved.")
      refute has_element?(view, "#privacy-show-online[checked]")

      view
      |> form("#contacts-form",
        contacts: %{friend_requests: "nobody", group_adds: "nobody", lobby_invites: "friends"}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         body: %{
                           "friend_requests" => "nobody",
                           "group_adds" => "nobody",
                           "lobby_invites" => "friends"
                         }
                       }}

      assert has_element?(view, "#contacts-status", "Contact permissions saved.")
      assert has_element?(view, "#privacy-friend-requests-nobody[checked]")
    end

    test "a refused value stays next to its field; social down → local notice", ctx do
      view =
        open(ctx.conn, ctx.user, %{
          {"GET", "/api/me/settings"} => %{"settings" => settings()},
          {"PATCH", "/api/me/settings"} =>
            {422, %{"error" => "invalid", "errors" => %{"group_adds" => ["is invalid"]}}}
        })

      view
      |> form("#contacts-form",
        contacts: %{friend_requests: "everyone", group_adds: "nobody", lobby_invites: "friends"}
      )
      |> render_submit()

      assert has_element?(view, "#privacy-group-adds-error", "is invalid")
      refute has_element?(view, "#contacts-status span")

      view = open(ctx.conn, ctx.user, %{{"GET", "/api/me/settings"} => :unavailable})
      assert has_element?(view, "#privacy-unavailable")
    end
  end

  describe "/media/attachments/:id" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    defp fetch(conn, routes, id) do
      stub_api(routes)
      conn |> log_in() |> get(~p"/media/attachments/#{id}")
    end

    test "an image is shown inline, never cached, sandboxed; the type comes from the bytes",
         ctx do
      routes =
        Map.put(member_routes(ctx.user), {"GET", "/api/attachments/a1"}, fn conn, _ ->
          Plug.Conn.send_resp(conn, 200, @png)
        end)

      conn = fetch(ctx.conn, routes, "a1")
      assert response(conn, 200) == @png
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
      assert get_resp_header(conn, "content-disposition") == []
      assert_received {:api, %{method: "GET", path: "/api/attachments/a1"}}
    end

    test "a PDF is ALWAYS a download", ctx do
      routes =
        Map.put(member_routes(ctx.user), {"GET", "/api/attachments/p1"}, fn conn, _ ->
          Plug.Conn.send_resp(conn, 200, @pdf)
        end)

      conn = fetch(ctx.conn, routes, "p1")
      assert get_resp_header(conn, "content-type") == ["application/pdf"]
      assert get_resp_header(conn, "content-disposition") == ["attachment"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "not a member (social 404), unknown bytes, or no session: 404", ctx do
      routes =
        Map.merge(member_routes(ctx.user), %{
          {"GET", "/api/attachments/x1"} => {404, %{"error" => "not_found"}},
          {"GET", "/api/attachments/x2"} => fn conn, _ ->
            Plug.Conn.send_resp(conn, 200, "<svg/>")
          end
        })

      assert fetch(ctx.conn, routes, "x1") |> response(404)
      assert fetch(ctx.conn, routes, "x2") |> response(404)
      assert ctx.conn |> get(~p"/media/attachments/x1") |> response(404)
    end
  end

  describe "staff: attachment of a reported message" do
    setup do
      %{moderator: staff("moderator")}
    end

    test "evidence shows the attachment; downloading it needs a reason, audited by social", ctx do
      evidence = %{
        "body" => nil,
        "sender" => person("u-orion", "hugo_bernard"),
        "sent_at" => "2026-11-23T09:00:00Z",
        "removed" => false,
        "attachment" => %{
          "id" => "a1",
          "kind" => "image",
          "content_type" => "image/png",
          "filename" => "insult.png",
          "byte_size" => 2048,
          "available" => true
        }
      }

      routes =
        Map.merge(member_routes(ctx.moderator), %{
          {"GET", "/api/moderation/reports/sr1"} => %{"report" => social_report()},
          {"POST", "/api/moderation/reports/sr1/evidence"} => %{"evidence" => evidence},
          {"POST", "/api/moderation/reports/sr1/attachment"} => fn conn, body ->
            if String.length(body["reason"]) < 10,
              do: {422, %{"error" => "invalid", "errors" => %{"reason" => ["too short"]}}},
              else: Plug.Conn.send_resp(conn, 200, @png)
          end
        })

      stub_api(routes)
      {:ok, view, _} = ctx.conn |> log_in() |> live(~p"/admin/reports/social/sr1")

      view
      |> form("#evidence-form", evidence: %{reason: "Harassment report review"})
      |> render_submit()

      assert has_element?(view, "#evidence-attachment", "insult.png")

      assert has_element?(
               view,
               "#attachment-evidence-form[action='/admin/reports/social/sr1/attachment'][method=post]"
             )

      conn =
        ctx.conn
        |> log_in()
        |> post(~p"/admin/reports/social/sr1/attachment", %{
          attachment: %{reason: "Reviewing the reported image"}
        })

      assert response(conn, 200) == @png
      assert get_resp_header(conn, "content-disposition") == ["attachment"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/moderation/reports/sr1/attachment",
                         body: %{"reason" => "Reviewing the reported image"}
                       }}

      conn =
        ctx.conn
        |> log_in()
        |> post(~p"/admin/reports/social/sr1/attachment", %{attachment: %{reason: "short"}})

      assert redirected_to(conn) == ~p"/admin/reports/social/sr1"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "at least 10 characters"
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
