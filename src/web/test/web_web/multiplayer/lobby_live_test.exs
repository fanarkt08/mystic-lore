defmodule MysticWeb.Multiplayer.LobbyLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.MultiplayerFixtures

  setup do
    user = user_fixture()
    me = player(user["id"], "Léa Moreau")
    hugo = player(uuid(), "Hugo Bernard")
    id = uuid()
    lobby = lobby_summary(%{"id" => id, "host" => hugo})

    waiting =
      lobby_detail(lobby, [member(hugo, %{"host" => true, "ready" => true}), member(me)])

    routes =
      Map.merge(member_routes(user), %{
        {"GET", "/api/lobbies/#{id}"} => waiting,
        {"GET", "/api/lobbies/#{id}/messages"} => %{
          "entries" => [chat_message("c1", hugo, "Moon is first, I think!")],
          "next_before" => nil
        },
        {"POST", "/api/lobbies/#{id}/heartbeat"} => {204, nil},
        {"GET", "/api/me/friends"} => %{"friends" => []}
      })

    %{user: user, me: me, hugo: hugo, id: id, lobby: lobby, waiting: waiting, routes: routes}
  end

  defp open(conn, routes, id) do
    stub_api(routes)
    {:ok, view, _html} = conn |> log_in() |> live(~p"/multiplayer/lobbies/#{id}")
    view
  end

  defp subscribed?(view, id),
    do:
      Enum.any?(Registry.lookup(MlShared.PubSub, "lobby:#{id}"), fn {pid, _} ->
        pid == view.pid
      end)

  test "subscribes to lobby:<id> only after a successful access check, then loads the state", %{
    conn: conn,
    routes: routes,
    id: id,
    waiting: waiting
  } do
    test = self()

    routes =
      Map.put(routes, {"GET", "/api/lobbies/#{id}"}, fn _conn, _ ->
        mine =
          Enum.any?(Registry.lookup(MlShared.PubSub, "lobby:#{id}"), fn {pid, _} ->
            pid == self()
          end)

        send(test, {:loaded, mine})
        waiting
      end)

    view = open(conn, routes, id)
    # static render, then (connected) access check, subscription, state
    assert_received {:loaded, false}
    assert_received {:loaded, false}
    assert_received {:loaded, true}
    assert subscribed?(view, id)
    assert has_element?(view, "#lobby-title", "Relais du soir")
    assert has_element?(view, "#chat-log", "Moon is first, I think!")

    # the first heartbeat is sent as soon as the member is in the lobby
    render(view)
    assert_received {:api, %{method: "POST", path: "/api/lobbies/" <> _}}
  end

  test "private or unknown lobby (404): clear message, no subscription, no heartbeat", %{
    conn: conn,
    routes: routes,
    id: id
  } do
    view =
      open(
        conn,
        Map.put(routes, {"GET", "/api/lobbies/#{id}"}, {404, %{"error" => "not_found"}}),
        id
      )

    assert has_element?(view, "#lobby-not-found")
    refute subscribed?(view, id)
    render(view)
    refute_received {:api, %{method: "POST"}}
  end

  test "the heartbeat repeats with Process.send_after and stops when the member is no longer in",
       %{
         conn: conn,
         routes: routes,
         id: id,
         waiting: waiting
       } do
    view = open(conn, routes, id)
    render(view)
    assert_received {:api, %{method: "POST", path: "/api/lobbies/" <> rest}}
    assert rest == "#{id}/heartbeat"

    send(view.pid, :heartbeat)
    render(view)
    assert_received {:api, %{method: "POST", path: "/api/lobbies/" <> _}}

    # removed by the host: the next reload says so, the subscription ends, no more heartbeats
    stub_api(Map.put(routes, {"GET", "/api/lobbies/#{id}"}, {403, %{"error" => "banned"}}))
    send(view.pid, {:lobby_changed, id})
    assert has_element?(view, "#lobby-banned")
    refute subscribed?(view, id)
    send(view.pid, :heartbeat)
    render(view)
    refute_received {:api, %{method: "POST"}}
    assert waiting["role"] == "player"
  end

  test "ready check: toggles ready and reloads on lobby_changed; unrelated messages are ignored",
       %{
         conn: conn,
         routes: routes,
         id: id,
         waiting: waiting,
         me: me
       } do
    routes = Map.put(routes, {"POST", "/api/lobbies/#{id}/ready"}, {204, nil})
    view = open(conn, routes, id)
    assert has_element?(view, "#ready-toggle[aria-pressed=false]", "I'm ready")
    refute has_element?(view, "#start-game")

    view |> element("#ready-toggle") |> render_click()

    assert_received {:api,
                     %{method: "POST", path: "/api/lobbies/" <> _, body: %{"ready" => true}}}

    members = [hd(waiting["members"]), member(me, %{"ready" => true})]
    stub_api(Map.put(routes, {"GET", "/api/lobbies/#{id}"}, %{waiting | "members" => members}))
    send(view.pid, {:lobby_changed, id})
    send(view.pid, {:something_else, :ignored})
    assert has_element?(view, "#ready-toggle[aria-pressed=true]")
    assert has_element?(view, "#ready-count", "2 players ready")
  end

  test "host: start, invitations of friends, temporary link created once then revoked, removal",
       %{
         conn: conn,
         routes: routes,
         id: id,
         lobby: lobby,
         me: me,
         hugo: hugo
       } do
    friend = player(uuid(), "Inès Petit")

    detail =
      lobby_detail(
        Map.put(lobby, "host", me),
        [member(me, %{"host" => true, "ready" => true}), member(hugo, %{"ready" => true})],
        %{
          "role" => "host",
          "links" => [
            %{
              "id" => "link-1",
              "state" => "active",
              "max_uses" => 5,
              "uses" => 1,
              "expires_at" => "2026-11-23T12:00:00Z",
              "revoked_at" => nil,
              "inserted_at" => "2026-11-23T11:00:00Z"
            }
          ]
        }
      )

    routes =
      Map.merge(routes, %{
        {"GET", "/api/lobbies/#{id}"} => detail,
        {"GET", "/api/me/friends"} => %{"friends" => [friend, hugo]},
        {"POST", "/api/lobbies/#{id}/start"} => {201, %{"match_id" => "m1"}},
        {"POST", "/api/lobbies/#{id}/invites"} => {201, %{"invite" => %{"id" => "i1"}}},
        {"POST", "/api/lobbies/#{id}/links"} =>
          {201, %{"link" => %{"id" => "link-2", "token" => "tok-secret-123"}}},
        {"DELETE", "/api/lobbies/#{id}/links/link-1"} => {204, nil},
        {"POST", "/api/lobbies/#{id}/kick"} => {204, nil}
      })

    view = open(conn, routes, id)

    start_path = "/api/lobbies/#{id}/start"
    view |> element("#start-game") |> render_click()
    assert_received {:api, %{method: "POST", path: ^start_path}}

    # friends already in the lobby are not offered
    refute has_element?(view, "#friend-#{hugo["id"]}")
    friend_id = friend["id"]
    view |> element("#invite-#{friend_id}") |> render_click()
    assert_received {:api, %{path: "/api/lobbies/" <> _, body: %{"user_id" => ^friend_id}}}
    assert render(view) =~ "Invitation sent."

    view |> form("#link-form", link: %{max_uses: "1", minutes: "15"}) |> render_submit()

    assert_received {:api,
                     %{method: "POST", body: %{"max_uses" => 1, "expires_in_minutes" => 15}}}

    assert has_element?(view, "#new-link-url[value$='/multiplayer/join/tok-secret-123']")

    view |> element("#revoke-link-1") |> render_click()
    assert_received {:api, %{method: "DELETE"}}
    refute has_element?(view, "#new-link")

    orion_id = hugo["id"]
    view |> element("#kick-#{orion_id}") |> render_click()
    assert_received {:api, %{path: "/api/lobbies/" <> _, body: %{"user_id" => ^orion_id}}}
  end

  test "chat: send, real-time reload on chat_posted, rate limit explained", %{
    conn: conn,
    routes: routes,
    id: id,
    me: me,
    hugo: hugo
  } do
    routes =
      Map.put(
        routes,
        {"POST", "/api/lobbies/#{id}/messages"},
        {201, %{"message" => chat_message("c2", me, "Hi!")}}
      )

    view = open(conn, routes, id)
    view |> form("#chat-form", chat: %{body: "  Hi!  "}) |> render_submit()
    assert_received {:api, %{method: "POST", body: %{"body" => "Hi!"}}}

    messages = %{
      "entries" => [
        chat_message("c1", hugo, "Moon is first, I think!"),
        chat_message("c3", hugo, "Star last.")
      ],
      "next_before" => nil
    }

    stub_api(Map.put(routes, {"GET", "/api/lobbies/#{id}/messages"}, messages))
    MlShared.Events.broadcast("lobby:#{id}", {:chat_posted, id})
    assert has_element?(view, "#chat-c3", "Star last.")

    stub_api(
      Map.put(
        routes,
        {"POST", "/api/lobbies/#{id}/messages"},
        {429, %{"error" => "rate_limited"}}
      )
    )

    view |> form("#chat-form", chat: %{body: "again"}) |> render_submit()
    assert has_element?(view, "#chat-form", "sending messages too fast")
  end

  test "report goes through the multiplayer service; block calls social", %{
    conn: conn,
    routes: routes,
    id: id,
    hugo: hugo
  } do
    routes =
      Map.merge(routes, %{
        {"POST", "/api/lobbies/#{id}/reports"} => {201, %{"id" => "r1"}},
        {"POST", "/api/blocks"} => {204, nil}
      })

    view = open(conn, routes, id)
    orion_id = hugo["id"]
    view |> element("#report-#{orion_id}") |> render_click()
    view |> form("#report-form", report: %{reason: "spam", details: "ads"}) |> render_submit()

    assert_received {:api,
                     %{
                       path: "/api/lobbies/" <> _,
                       body: %{"user_id" => ^orion_id, "reason" => "spam", "details" => "ads"}
                     }}

    view |> element("#block-#{orion_id}") |> render_click()

    assert_received {:api,
                     %{method: "POST", path: "/api/blocks", body: %{"user_id" => ^orion_id}}}

    assert render(view) =~ "Member blocked"
  end

  test "lobby → game → victory: private clues, keyboard-friendly rune grid, scored attempts, live announcements",
       %{conn: conn, routes: routes, id: id, waiting: waiting, me: me, hugo: hugo} do
    view = open(conn, routes, id)
    hints = [%{"kind" => "at", "pos" => 0, "rune" => 0}, %{"kind" => "absent", "rune" => 7}]
    game = match([me, hugo], %{"my_hints" => hints})
    playing = %{waiting | "lobby" => %{waiting["lobby"] | "status" => "playing"}, "match" => game}

    stub_api(Map.merge(routes, %{{"GET", "/api/lobbies/#{id}"} => playing}))
    send(view.pid, {:lobby_changed, id})

    assert has_element?(view, "#mp-announce", "The game has started. It's your turn.")
    assert has_element?(view, "#my-hints", "Ember is in position 1.")
    assert has_element?(view, "#my-hints", "Eye is not in the sequence.")
    assert has_element?(view, "#rune-grid[role=group][phx-hook]")
    assert has_element?(view, "#propose[disabled]")

    for rune <- [0, 4, 5, 1, 4, 2, 3], do: view |> element("#rune-#{rune}") |> render_click()
    # rune 4 picked twice = removed: Ember, Moon, Storm, Mist, Stone
    assert has_element?(view, "#rune-0[aria-pressed=true]", "position 1")
    assert has_element?(view, "#rune-4[aria-pressed=false]")
    assert has_element?(view, "#current-guess", "Ember, Moon, Storm, Mist, Stone")

    marks = ~w(hit present present miss miss)
    tried = attempt(1, me["id"], [0, 5, 1, 2, 3], marks)

    after_attempt =
      put_in(playing, ["match"], %{
        game
        | "attempts" => [tried],
          "attempts_left" => 5,
          "current_player" => hugo["id"]
      })

    stub_api(
      Map.merge(routes, %{
        {"POST", "/api/lobbies/#{id}/attempts"} => %{"match" => after_attempt["match"]},
        {"GET", "/api/lobbies/#{id}"} => after_attempt
      })
    )

    view |> element("#propose") |> render_click()
    assert_received {:api, %{method: "POST", body: %{"sequence" => [0, 5, 1, 2, 3]}}}
    assert has_element?(view, "#attempt-1", "Attempt 1 by Léa Moreau")
    assert has_element?(view, "#attempt-1 .mp-mark-hit", "right place")
    assert has_element?(view, "#attempt-1 .mp-mark-miss .hero-x-circle")

    assert has_element?(
             view,
             "#mp-announce",
             "1 in the right place, 2 in the wrong place. It's Hugo Bernard's turn."
           )

    assert has_element?(view, "#current-guess", "empty")

    won = attempt(2, hugo["id"], [0, 1, 5, 2, 3], List.duplicate("hit", 5))

    victory =
      %{
        waiting
        | "match" => %{
            game
            | "status" => "won",
              "attempts" => [tried, won],
              "current_player" => nil,
              "secret" => [0, 1, 5, 2, 3],
              "my_reward" => %{"amount" => 50, "status" => "awarded"}
          }
      }

    stub_api(Map.put(routes, {"GET", "/api/lobbies/#{id}"}, victory))
    MlShared.Events.broadcast("lobby:#{id}", {:lobby_changed, id})

    assert has_element?(view, "#game-won", "Ember, Storm, Moon, Mist, Stone")
    assert has_element?(view, "#my-reward", "+50 XP added to your progress.")
    assert has_element?(view, "#mp-announce", "Victory!")
    refute has_element?(view, "#composer")
    assert has_element?(view, "#ready-check", "Next game")
  end

  test "spectator joins; invited member accepts", %{
    conn: conn,
    routes: routes,
    id: id,
    waiting: waiting
  } do
    spectator = %{waiting | "role" => "spectator"}

    routes =
      Map.merge(routes, %{
        {"GET", "/api/lobbies/#{id}"} => spectator,
        {"POST", "/api/lobbies/#{id}/join"} => %{"status" => "joined"}
      })

    view = open(conn, routes, id)
    refute has_element?(view, "#chat")
    view |> element("#join-lobby") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/lobbies/" <> _}}
    assert render(view) =~ "You joined the activity."

    invited = %{waiting | "role" => "invited", "my_invite_id" => "inv-1"}

    stub_api(
      Map.merge(routes, %{
        {"GET", "/api/lobbies/#{id}"} => invited,
        {"POST", "/api/invites/inv-1/accept"} => %{"lobby_id" => id}
      })
    )

    send(view.pid, {:lobby_changed, id})
    view |> element("#accept-invite") |> render_click()
    assert_received {:api, %{method: "POST", path: "/api/invites/inv-1/accept"}}
  end
end
