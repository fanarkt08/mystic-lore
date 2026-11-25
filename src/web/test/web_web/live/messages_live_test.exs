defmodule MysticWeb.MessagesLiveTest do
  use MysticWeb.ConnCase, async: true

  setup do
    user = user_fixture()
    hugo = member_fixture()
    conversation_id = uuid()
    conversation = direct_conversation(conversation_id, user, hugo, %{"unread" => 2})

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/me/conversations"} => %{"conversations" => [conversation]},
        {"GET", "/api/conversations/#{conversation_id}"} => %{"conversation" => conversation},
        {"GET", "/api/conversations/#{conversation_id}/messages"} => %{
          "entries" => [message("m1", conversation_id, hugo["id"], "Hello Léa!")],
          "next_before" => nil,
          "users" => [hugo]
        },
        {"POST", "/api/conversations/#{conversation_id}/read"} => {204, nil},
        {"GET", "/api/me/friends"} => %{"friends" => [Map.put(hugo, "online_visible", true)]}
      })

    %{user: user, hugo: hugo, cid: conversation_id, conversation: conversation, routes: routes}
  end

  defp open(conn, routes, path) do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(path)
    view
  end

  defp count(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  defp deliver(user, event), do: MlShared.Events.broadcast("user:#{user["id"]}", event)

  test "lists conversations with their unread count", %{conn: conn, routes: routes, cid: cid} do
    view = open(conn, routes, ~p"/messages")
    assert has_element?(view, "#conversation-#{cid}", "Hugo Bernard")
    assert has_element?(view, "#conversation-#{cid} .count-badge", "2")
    assert has_element?(view, "a#new-group[href='/messages/new']")
  end

  test "never subscribes to a conversation: social delivers to the member's own topic", %{
    conn: conn,
    routes: routes,
    cid: cid
  } do
    view = open(conn, routes, ~p"/messages/#{cid}")
    assert has_element?(view, "#message-m1", "Hello Léa!")
    assert Registry.lookup(MlShared.PubSub, "conversation:#{cid}") == []
    assert_received {:api, %{method: "POST", path: "/api/conversations/" <> _}}
    _ = view
  end

  test "receives messages in real time, without duplicates; other conversations stay out of the thread",
       %{conn: conn, routes: routes, cid: cid, user: user, hugo: hugo} do
    view = open(conn, routes, ~p"/messages/#{cid}")

    incoming = message("m2", cid, hugo["id"], "Shall we water the grove?")
    deliver(user, {:new_message, incoming})
    deliver(user, {:new_message, incoming})
    assert has_element?(view, "#message-m2", "Shall we water the grove?")

    deliver(user, {:new_message, message("x1", uuid(), hugo["id"], "elsewhere")})
    refute has_element?(view, "#message-x1")

    sent = message("m3", cid, user["id"], "On my way!")

    stub_api(
      Map.put(routes, {"POST", "/api/conversations/#{cid}/messages"}, {201, %{"message" => sent}})
    )

    view |> form("#composer", message: %{body: "On my way!"}) |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/conversations/" <> _,
                       body: %{"body" => "On my way!"}
                     }}

    # The same message also comes back through the member's topic (another tab).
    deliver(user, {:new_message, sent})

    assert count(view, "#message-m2") == 1
    assert count(view, "#message-m3") == 1
    assert has_element?(view, "#message-m3.bubble-mine")
  end

  test "a conversation that isn't the member's (404): not found, no message shown", %{
    conn: conn,
    routes: routes,
    user: user
  } do
    other_id = uuid()

    routes =
      Map.put(routes, {"GET", "/api/conversations/#{other_id}"}, {404, %{"error" => "not_found"}})

    view = open(conn, routes, ~p"/messages/#{other_id}")

    assert has_element?(view, "#conversation-not-found")
    refute_received {:api, %{path: "/api/conversations/" <> _, method: "POST"}}

    deliver(user, {:new_message, message("x1", other_id, uuid(), "secret")})
    refute render(view) =~ "secret"
  end

  test "removed from the conversation while the page is open: reloaded on conversation_changed (404), cleared",
       %{conn: conn, routes: routes, cid: cid, user: user} do
    view = open(conn, routes, ~p"/messages/#{cid}")
    assert has_element?(view, "#message-m1")

    stub_api(%{routes | {"GET", "/api/conversations/#{cid}"} => {404, %{"error" => "not_found"}}})
    deliver(user, {:conversation_changed, cid})

    assert has_element?(view, "#conversation-not-found")
    refute has_element?(view, "#message-m1")
    refute has_element?(view, "#composer")
  end

  test "load older messages keeps the chronological order", %{
    conn: conn,
    routes: routes,
    cid: cid,
    hugo: hugo
  } do
    routes =
      Map.put(routes, {"GET", "/api/conversations/#{cid}/messages"}, fn conn, _ ->
        case URI.decode_query(conn.query_string) do
          %{"before" => "m1"} ->
            %{
              "entries" => [
                message("m0a", cid, hugo["id"], "First"),
                message("m0b", cid, hugo["id"], "Second")
              ],
              "next_before" => nil,
              "users" => [hugo]
            }

          _ ->
            %{
              "entries" => [message("m1", cid, hugo["id"], "Third")],
              "next_before" => "m1",
              "users" => [hugo]
            }
        end
      end)

    view = open(conn, routes, ~p"/messages/#{cid}")
    view |> element("#load-older") |> render_click()

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#messages > li[id^='message-']")
      |> Enum.map(&LazyHTML.attribute(&1, "id"))
      |> List.flatten()

    assert ids == ["message-m0a", "message-m0b", "message-m1"]
    refute has_element?(view, "#load-older")
  end

  test "sending is disabled with a clear message when no longer friends", %{
    conn: conn,
    routes: routes,
    cid: cid
  } do
    view =
      open(
        conn,
        %{routes | {"GET", "/api/me/friends"} => %{"friends" => []}},
        ~p"/messages/#{cid}"
      )

    assert has_element?(view, "#composer-locked", "can't send messages anymore")
    assert has_element?(view, "#message_body[disabled]")
    assert has_element?(view, "#message-m1")
  end

  test "a refused send (403 blocked) locks the composer", %{conn: conn, routes: routes, cid: cid} do
    view =
      open(
        conn,
        Map.put(
          routes,
          {"POST", "/api/conversations/#{cid}/messages"},
          {403, %{"error" => "blocked"}}
        ),
        ~p"/messages/#{cid}"
      )

    view |> form("#composer", message: %{body: "Hello?"}) |> render_submit()
    assert has_element?(view, "#composer-locked", "blocked")
    assert has_element?(view, "#send-message[disabled]")
  end

  test "429: the delay given by social is shown, sending is disabled until it is over; the text is kept",
       %{conn: conn, routes: routes, cid: cid} do
    view =
      open(
        conn,
        Map.put(
          routes,
          {"POST", "/api/conversations/#{cid}/messages"},
          {429, %{"error" => "rate_limited", "retry_after" => 7}}
        ),
        ~p"/messages/#{cid}"
      )

    view |> form("#composer", message: %{body: "Too fast"}) |> render_submit()
    assert has_element?(view, "#composer-throttled[role=alert]", "in 7 seconds")
    assert has_element?(view, "#send-message[disabled]")
    assert has_element?(view, "#message_body", "Too fast")

    send(view.pid, :throttle_over)
    refute has_element?(view, "#composer-throttled")
    refute has_element?(view, "#send-message[disabled]")
  end

  test "the unread badge of the rail follows unread_changed in real time", %{
    conn: conn,
    routes: routes,
    user: user
  } do
    view = open(conn, routes, ~p"/messages")
    refute has_element?(view, "#nav-messages .count-badge")

    stub_api(%{routes | {"GET", "/api/me/unread"} => %{"messages" => 3, "friend_requests" => 1}})
    deliver(user, {:unread_changed, user["id"]})

    assert has_element?(view, "#nav-messages .count-badge", "3")
    assert has_element?(view, "#nav-friends .count-badge", "1")
    assert has_element?(view, "#unread-status", "3 unread messages")
  end

  describe "read receipts" do
    test "« Seen » under my latest message once the other has read it, live", ctx do
      mine = message("m9", ctx.cid, ctx.user["id"], "Did you read it?")

      routes =
        Map.put(ctx.routes, {"GET", "/api/conversations/#{ctx.cid}/messages"}, %{
          "entries" => [message("m1", ctx.cid, ctx.hugo["id"], "Hi"), mine],
          "next_before" => nil,
          "users" => [ctx.hugo]
        })

      view = open(ctx.conn, routes, ~p"/messages/#{ctx.cid}")
      refute has_element?(view, "#read-receipt")

      deliver(
        ctx.user,
        {:messages_read, ctx.cid,
         %{"user_id" => ctx.hugo["id"], "read_at" => "2026-11-23T09:31:00Z"}}
      )

      assert has_element?(view, "#read-receipt", "Seen")

      # a read older than my message is not a « Seen »
      deliver(
        ctx.user,
        {:messages_read, ctx.cid,
         %{"user_id" => ctx.hugo["id"], "read_at" => "2026-11-23T09:00:00Z"}}
      )

      refute has_element?(view, "#read-receipt")
    end

    test "receipts off (reciprocity): nothing shown, and a hint in the details", ctx do
      mine = message("m9", ctx.cid, ctx.user["id"], "Read?")

      conversation =
        Map.put(ctx.conversation, "read_receipts", %{"enabled" => false, "reads" => []})

      routes =
        Map.merge(ctx.routes, %{
          {"GET", "/api/conversations/#{ctx.cid}"} => %{"conversation" => conversation},
          {"GET", "/api/conversations/#{ctx.cid}/messages"} => %{
            "entries" => [mine],
            "next_before" => nil,
            "users" => []
          }
        })

      view = open(ctx.conn, routes, ~p"/messages/#{ctx.cid}")
      refute has_element?(view, "#read-receipt")
      view |> element("#toggle-details") |> render_click()
      assert has_element?(view, "#receipts-off a[href='/settings/privacy']")
    end
  end

  describe "mute" do
    test "mute for a duration, then unmute (the conversation returned by social is shown)", ctx do
      muted = %{ctx.conversation | "muted" => true, "muted_until" => "2026-11-23T18:00:00Z"}

      view =
        open(
          ctx.conn,
          Map.merge(ctx.routes, %{
            {"PUT", "/api/conversations/#{ctx.cid}/mute"} => %{"conversation" => muted},
            {"DELETE", "/api/conversations/#{ctx.cid}/mute"} => %{
              "conversation" => ctx.conversation
            }
          }),
          ~p"/messages/#{ctx.cid}"
        )

      view |> element("#toggle-details") |> render_click()
      assert has_element?(view, "#toggle-details[aria-expanded=true]")
      view |> form("#mute-form", mute: %{duration: "24h"}) |> render_submit()

      assert_received {:api,
                       %{
                         method: "PUT",
                         path: "/api/conversations/" <> _,
                         body: %{"duration" => "24h"}
                       }}

      assert has_element?(view, "#mute-status", "Muted until")
      assert has_element?(view, "#thread-muted")

      view |> element("#unmute") |> render_click()
      assert_received {:api, %{method: "DELETE", path: "/api/conversations/" <> _}}
      refute has_element?(view, "#thread-muted")
    end

    test "a muted conversation keeps its own counter, marked as muted in the list", ctx do
      muted = %{ctx.conversation | "muted" => true, "muted_until" => nil}

      view =
        open(
          ctx.conn,
          %{ctx.routes | {"GET", "/api/me/conversations"} => %{"conversations" => [muted]}},
          ~p"/messages"
        )

      assert has_element?(view, "#conversation-#{ctx.cid} .count-badge.count-badge-muted", "2")
      assert has_element?(view, "#conversation-#{ctx.cid}", "Muted")
    end
  end
end
