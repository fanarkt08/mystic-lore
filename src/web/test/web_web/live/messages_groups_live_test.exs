defmodule MysticWeb.MessagesGroupsLiveTest do
  @moduledoc "Groups, attachments and online dots in /messages (social stubbed)."
  use MysticWeb.ConnCase, async: true

  setup do
    user = user_fixture()
    hugo = member_fixture()
    ines = member_fixture(%{"username" => "ines_petit", "display_name" => "Inès Petit"})
    gid = uuid()
    group = group_conversation(gid, user, [hugo, ines], %{"name" => "Night owls"})

    created = %{
      message("s1", gid, user["id"], nil)
      | "kind" => "system",
        "system" => %{"event" => "created", "actor_id" => user["id"], "name" => "Night owls"}
    }

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/conversations"} => %{"conversations" => [group]},
        {"GET", "/api/conversations/#{gid}"} => %{"conversation" => group},
        {"GET", "/api/conversations/#{gid}/messages"} => %{
          "entries" => [
            created,
            message("m1", gid, hugo["id"], "Hello circle"),
            %{message("h1", gid, nil, nil) | "hidden" => true}
          ],
          "next_before" => nil,
          "users" => [user, hugo]
        },
        {"POST", "/api/conversations/#{gid}/read"} => {204, nil},
        {"GET", "/api/me/friends"} => %{
          "friends" => [
            Map.put(hugo, "online_visible", true),
            Map.put(ines, "online_visible", false)
          ]
        }
      })

    %{user: user, hugo: hugo, ines: ines, gid: gid, group: group, routes: routes}
  end

  defp open(conn, routes, path) do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(path)
    view
  end

  defp deliver(user, event), do: MlShared.Events.broadcast("user:#{user["id"]}", event)

  describe "thread of a group" do
    test "system message phrased by web, sender names, hidden message", ctx do
      view = open(ctx.conn, ctx.routes, ~p"/messages/#{ctx.gid}")
      assert has_element?(view, "#thread-title", "Night owls")
      assert has_element?(view, "#thread-subtitle", "3 members")

      assert has_element?(
               view,
               "#message-s1.system-line",
               "Léa Moreau created the group “Night owls”."
             )

      assert has_element?(view, "#message-m1 .bubble-sender", "Hugo Bernard")
      assert has_element?(view, "#message-h1.bubble-hidden", "Hidden message")
      refute has_element?(view, "#report-h1")
    end

    test "a live system message reloads the members before it is shown", ctx do
      view = open(ctx.conn, ctx.routes, ~p"/messages/#{ctx.gid}")
      nova = member_fixture(%{"username" => "nova", "display_name" => "Nova Star"})

      bigger =
        group_conversation(ctx.gid, ctx.user, [ctx.hugo, ctx.ines, nova], %{
          "name" => "Night owls"
        })

      stub_api(%{
        ctx.routes
        | {"GET", "/api/conversations/#{ctx.gid}"} => %{"conversation" => bigger}
      })

      added = %{
        message("s2", ctx.gid, ctx.user["id"], nil)
        | "kind" => "system",
          "system" => %{
            "event" => "member_added",
            "actor_id" => ctx.user["id"],
            "target_id" => nova["id"]
          }
      }

      deliver(ctx.user, {:new_message, added})
      assert has_element?(view, "#message-s2", "Léa Moreau added Nova Star.")
      assert has_element?(view, "#thread-subtitle", "4 members")
    end

    test "« Seen by N » with the names, for my latest message", ctx do
      mine = message("m9", ctx.gid, ctx.user["id"], "Tonight?")

      group =
        Map.put(ctx.group, "read_receipts", %{
          "enabled" => true,
          "reads" => [
            %{"user_id" => ctx.hugo["id"], "read_at" => "2026-11-23T09:40:00Z"},
            %{"user_id" => ctx.ines["id"], "read_at" => "2026-11-23T09:00:00Z"}
          ]
        })

      routes =
        Map.merge(ctx.routes, %{
          {"GET", "/api/conversations/#{ctx.gid}"} => %{"conversation" => group},
          {"GET", "/api/conversations/#{ctx.gid}/messages"} => %{
            "entries" => [mine],
            "next_before" => nil,
            "users" => [ctx.user]
          }
        })

      view = open(ctx.conn, routes, ~p"/messages/#{ctx.gid}")
      assert has_element?(view, "#read-receipt", "Seen by 1: Hugo Bernard")

      deliver(
        ctx.user,
        {:messages_read, ctx.gid,
         %{"user_id" => ctx.ines["id"], "read_at" => "2026-11-23T09:45:00Z"}}
      )

      assert has_element?(view, "#read-receipt", "Seen by 2")
      assert has_element?(view, "#read-receipt", "Inès Petit")
    end
  end

  describe "details panel" do
    test "the owner sees members with avatars and owner controls; destructive actions are confirmed",
         ctx do
      view = open(ctx.conn, ctx.routes, ~p"/messages/#{ctx.gid}")
      view |> element("#toggle-details") |> render_click()

      assert has_element?(view, "#member-#{ctx.user["id"]}", "Owner")
      assert has_element?(view, "#member-#{ctx.hugo["id"]} .avatar")
      assert has_element?(view, "#remove-member-#{ctx.hugo["id"]}[data-confirm]")
      refute has_element?(view, "#remove-member-#{ctx.user["id"]}")
      assert has_element?(view, "#leave-group[data-confirm]")
      assert has_element?(view, "#rename-form")
      # all friends are already members
      refute has_element?(view, "#add-member-id")
    end

    test "rename, remove and leave call social; refusals are explained", ctx do
      renamed = Map.put(ctx.group, "name", "Early birds")

      view =
        open(
          ctx.conn,
          Map.merge(ctx.routes, %{
            {"PATCH", "/api/conversations/#{ctx.gid}"} => %{"conversation" => renamed},
            {"DELETE", "/api/conversations/#{ctx.gid}/members/#{ctx.hugo["id"]}"} =>
              {403, %{"error" => "not_owner"}},
            {"POST", "/api/conversations/#{ctx.gid}/leave"} => {204, nil}
          }),
          ~p"/messages/#{ctx.gid}"
        )

      view |> element("#toggle-details") |> render_click()
      view |> form("#rename-form", group: %{name: "Early birds"}) |> render_submit()
      assert_received {:api, %{method: "PATCH", body: %{"name" => "Early birds"}}}
      assert has_element?(view, "#thread-title", "Early birds")

      view |> element("#remove-member-#{ctx.hugo["id"]}") |> render_click()
      assert render(view) =~ "Only the owner of the group can do that."

      view |> element("#leave-group") |> render_click()
      leave = "/api/conversations/#{ctx.gid}/leave"
      assert_received {:api, %{method: "POST", path: ^leave}}
      assert_patch(view, ~p"/messages")
    end

    test "a member who isn't the owner can only leave", ctx do
      group = %{ctx.group | "owner_id" => ctx.hugo["id"]}

      view =
        open(
          ctx.conn,
          %{ctx.routes | {"GET", "/api/conversations/#{ctx.gid}"} => %{"conversation" => group}},
          ~p"/messages/#{ctx.gid}"
        )

      view |> element("#toggle-details") |> render_click()
      refute has_element?(view, "#rename-form")
      refute has_element?(view, "[id^=remove-member-]")
      assert has_element?(view, "#leave-group")
    end
  end

  describe "group creation" do
    test "among friends; social's refusal names the member", ctx do
      view =
        open(
          ctx.conn,
          Map.put(ctx.routes, {"POST", "/api/groups"}, fn _conn, body ->
            if body["name"] == "Refused",
              do: {403, %{"error" => "group_adds_closed", "user_id" => ctx.ines["id"]}},
              else: {201, %{"conversation" => ctx.group}}
          end),
          ~p"/messages/new"
        )

      assert has_element?(view, "#new-group-form")
      assert has_element?(view, "#new-group-#{ctx.hugo["id"]}")

      view
      |> form("#new-group-form",
        group: %{name: "Refused", member_ids: [ctx.hugo["id"], ctx.ines["id"]]}
      )
      |> render_submit()

      assert has_element?(view, "#new-group-members-error", "Inès Petit can't be added")

      view
      |> form("#new-group-form",
        group: %{name: "Night owls", member_ids: [ctx.hugo["id"], ctx.ines["id"]]}
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/groups",
                         body: %{"name" => "Night owls", "member_ids" => ids}
                       }}

      assert Enum.sort(ids) == Enum.sort([ctx.hugo["id"], ctx.ines["id"]])
      assert_patch(view, ~p"/messages/#{ctx.gid}")
    end

    test "with fewer than 2 friends, explains why", ctx do
      view =
        open(
          ctx.conn,
          %{ctx.routes | {"GET", "/api/me/friends"} => %{"friends" => [ctx.hugo]}},
          ~p"/messages/new"
        )

      assert has_element?(view, "#new-group-few-friends")
    end
  end

  describe "attachments" do
    defp attachment(id, kind, attrs \\ %{}) do
      Map.merge(
        %{
          "id" => id,
          "kind" => kind,
          "content_type" => if(kind == "image", do: "image/png", else: "application/pdf"),
          "filename" => if(kind == "image", do: "map.png", else: "notes.pdf"),
          "byte_size" => 2_400_000,
          "width" => 320,
          "height" => 200,
          "alt" => nil,
          "scan" => "unscanned",
          "available" => true
        },
        attrs
      )
    end

    test "image preview with its description (or a fallback), PDF to download, « not scanned »",
         ctx do
      routes =
        Map.put(ctx.routes, {"GET", "/api/conversations/#{ctx.gid}/messages"}, %{
          "entries" => [
            %{
              message("i1", ctx.gid, ctx.hugo["id"], nil)
              | "attachment" => attachment("a1", "image", %{"alt" => "A star map"})
            },
            %{
              message("i2", ctx.gid, ctx.hugo["id"], "no alt")
              | "attachment" => attachment("a2", "image", %{"scan" => "clean"})
            },
            %{
              message("p1", ctx.gid, ctx.hugo["id"], nil)
              | "attachment" => attachment("a3", "pdf")
            },
            %{
              message("d1", ctx.gid, ctx.hugo["id"], "old")
              | "attachment" => attachment("a4", "pdf", %{"available" => false})
            }
          ],
          "next_before" => nil,
          "users" => [ctx.hugo]
        })

      view = open(ctx.conn, routes, ~p"/messages/#{ctx.gid}")

      assert has_element?(
               view,
               "#attachment-a1 img[src='/media/attachments/a1'][alt='A star map']"
             )

      assert has_element?(view, "#attachment-a1 .attachment-scan", "Not scanned by an antivirus")
      assert has_element?(view, "#attachment-a2 img[alt*='without a description']")
      refute has_element?(view, "#attachment-a2 .attachment-scan")

      assert has_element?(
               view,
               "#attachment-a3 a[href='/media/attachments/a3'][download='notes.pdf']",
               "2.3 MB"
             )

      assert has_element?(view, "#attachment-a4", "Attachment deleted")
      refute has_element?(view, "#attachment-a4 a")
    end

    test "upload with progress, alternative text, sent as base64; a refusal is shown next to the file",
         ctx do
      sent = %{
        message("n1", ctx.gid, ctx.user["id"], nil)
        | "attachment" => attachment("a9", "image")
      }

      view =
        open(
          ctx.conn,
          Map.put(ctx.routes, {"POST", "/api/conversations/#{ctx.gid}/messages"}, fn _conn,
                                                                                     body ->
            if body["attachment"]["filename"] == "fake.png",
              do:
                {422,
                 %{
                   "error" => "invalid",
                   "errors" => %{
                     "attachment" => ["must be a PNG, JPEG or WebP image, or a PDF document"]
                   }
                 }},
              else: {201, %{"message" => sent}}
          end),
          ~p"/messages/#{ctx.gid}"
        )

      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest-of-the-image">>

      fake =
        file_input(view, "#composer", :attachment, [
          %{name: "fake.png", content: "just text", type: "image/png"}
        ])

      assert render_upload(fake, "fake.png") =~ "fake.png"
      assert has_element?(view, "#attachment-alt")
      view |> form("#composer", message: %{body: "", alt: ""}) |> render_submit()

      assert has_element?(
               view,
               "#attachment-error",
               "must be a PNG, JPEG or WebP image, or a PDF document"
             )

      # the refused file is kept: it can be removed or replaced
      assert has_element?(view, "[id^=cancel-upload-]")
      view |> element("[id^=cancel-upload-]") |> render_click()

      image =
        file_input(view, "#composer", :attachment, [
          %{name: "map.png", content: png, type: "image/png"}
        ])

      render_upload(image, "map.png")

      view
      |> form("#composer", message: %{body: "Our map", alt: "A hand-drawn map"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         body: %{
                           "body" => "Our map",
                           "attachment" => %{
                             "filename" => "map.png",
                             "alt" => "A hand-drawn map",
                             "data_base64" => data
                           }
                         }
                       }}

      assert Base.decode64!(data) == png
      assert has_element?(view, "#message-n1 #attachment-a9")
      refute has_element?(view, "[id^=upload-]")
    end
  end

  describe "online dots" do
    test "only for friends who allow it, while one of their pages is connected", ctx do
      view = open(ctx.conn, ctx.routes, ~p"/messages/#{ctx.gid}")
      view |> element("#toggle-details") |> render_click()
      refute has_element?(view, "#member-#{ctx.hugo["id"]} .presence-dot")

      orion_page = spawn(fn -> Process.sleep(:infinity) end)
      mika_page = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _} = MysticWeb.Presence.track_member(orion_page, ctx.hugo["id"])
      {:ok, _} = MysticWeb.Presence.track_member(mika_page, ctx.ines["id"])

      # the diff is broadcast asynchronously: wait until the view shows it
      assert eventually(fn ->
               has_element?(view, "#member-#{ctx.hugo["id"]} .presence-dot", "Online")
             end)

      # Inès hides her status from her friends
      refute has_element?(view, "#member-#{ctx.ines["id"]} .presence-dot")

      Process.exit(orion_page, :kill)

      assert eventually(fn ->
               not has_element?(view, "#member-#{ctx.hugo["id"]} .presence-dot")
             end)

      Process.exit(mika_page, :kill)
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
