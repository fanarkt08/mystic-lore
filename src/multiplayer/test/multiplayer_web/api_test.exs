defmodule MlMultiplayerWeb.ApiTest do
  # GET /api/lobbies/:id pendant une partie interroge le MatchServer (autre processus) : sandbox partagée.
  use MlMultiplayerWeb.ConnCase, async: false
  alias MlMultiplayer.{Invitations, Lobbies}

  @salt "ml-internal-v1"

  test "GET /healthz répond sans jeton", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/healthz") |> json_response(200)
  end

  test "toute route /api exige un jeton interne valide portant un utilisateur (UUID)" do
    id = uuid()

    routes =
      [get: "/api/lobbies", post: "/api/lobbies", get: "/api/me/lobbies", get: "/api/me/invites"] ++
        for(
          action <-
            ~w(join leave ready start transfer kick heartbeat attempts reports messages invites links),
          do: {:post, "/api/lobbies/#{id}/#{action}"}
        ) ++
        [
          get: "/api/lobbies/#{id}",
          get: "/api/lobbies/#{id}/messages",
          post: "/api/lobbies/#{id}/requests/#{id}/approve",
          post: "/api/lobbies/#{id}/requests/#{id}/decline",
          delete: "/api/lobbies/#{id}/links/#{id}",
          post: "/api/invites/#{id}/accept",
          post: "/api/invites/#{id}/decline",
          post: "/api/links/preview",
          post: "/api/links/join"
        ]

    headers = [
      nil,
      "Bearer garbage",
      "Bearer " <> MlShared.InternalToken.sign("web"),
      "Bearer " <> MlShared.InternalToken.sign("web", "lea"),
      "Bearer " <>
        Plug.Crypto.sign(String.duplicate("x", 64), @salt, %{"svc" => "web", "sub" => id})
    ]

    for {method, path} <- routes, header <- headers do
      conn =
        if header, do: put_req_header(build_conn(), "authorization", header), else: build_conn()

      assert %{"error" => "unauthorized"} =
               conn |> dispatch(@endpoint, method, path) |> json_response(401),
             "#{method} #{path} accepté avec #{inspect(header)}"
    end
  end

  test "IDOR : un salon privé est invisible (404) pour un non-membre, quelle que soit l'action" do
    host = uuid()
    lobby = lobby!(host, %{"visibility" => "private"})
    stranger = uuid()
    base = "/api/lobbies/#{lobby.id}"

    for {method, path, body} <- [
          {:get, base, nil},
          {:post, base <> "/join", nil},
          {:get, base <> "/messages", nil},
          {:post, base <> "/messages", %{body: "hi"}},
          {:post, base <> "/heartbeat", nil},
          {:post, base <> "/ready", %{ready: true}},
          {:post, base <> "/attempts", %{sequence: [0, 1, 2, 3, 4]}},
          {:post, base <> "/invites", %{user_id: uuid()}},
          {:post, base <> "/links", %{}},
          {:post, base <> "/kick", %{user_id: host}},
          {:post, base <> "/reports", %{user_id: host, reason: "spam"}}
        ] do
      assert %{"error" => "not_found"} = api(method, path, stranger, body) |> json_response(404),
             "#{method} #{path}"
    end

    assert %{"lobby" => %{"id" => _}} = api(:get, base, host) |> json_response(200)
  end

  test "l'identité vient du jeton : actions d'hôte refusées (403) à un joueur, même en se déclarant hôte" do
    host = uuid()
    lobby = lobby!(host)
    guest = join!(lobby, uuid())
    base = "/api/lobbies/#{lobby.id}"

    for {path, body} <- [
          {"/kick", %{user_id: host, host_id: host}},
          {"/transfer", %{user_id: guest}},
          {"/start", %{as: host}},
          {"/invites", %{user_id: uuid()}},
          {"/links", %{}}
        ] do
      assert %{"error" => "forbidden"} =
               api(:post, base <> path, guest, body) |> json_response(403)
    end

    assert api(:post, base <> "/leave", uuid(), %{user_id: host}) |> json_response(403)
    assert {:ok, _, :host} = Lobbies.fetch(host, lobby.id)
  end

  test "parcours complet par l'API : création, prêts, partie, vues privées, victoire" do
    [host, guest] = [uuid(), uuid()]

    assert %{"lobby" => %{"id" => id, "member_count" => 1}, "role" => "host"} =
             api(:post, "/api/lobbies", host, %{
               title: "Relay",
               visibility: "open",
               max_players: 2
             })
             |> json_response(201)

    assert %{"status" => "joined"} =
             api(:post, "/api/lobbies/#{id}/join", guest) |> json_response(200)

    for user <- [host, guest],
        do: assert(api(:post, "/api/lobbies/#{id}/ready", user, %{ready: true}).status == 204)

    assert %{"error" => "invalid"} =
             api(:post, "/api/lobbies/#{id}/ready", host, %{ready: "yes"}) |> json_response(422)

    assert %{"match_id" => _} = api(:post, "/api/lobbies/#{id}/start", host) |> json_response(201)

    views =
      for user <- [host, guest] do
        %{"match" => match, "members" => members, "lobby" => %{"status" => "playing"}} =
          api(:get, "/api/lobbies/#{id}", user) |> json_response(200)

        assert Enum.all?(
                 members,
                 &match?(%{"user" => %{"username" => "user_" <> _}, "connection" => "online"}, &1)
               )

        assert match["secret"] == nil and match["my_hints"] != []
        assert Enum.all?(match["players"], &match?(%{"id" => _, "display_name" => _}, &1))
        {user, match}
      end

    [{_, host_view}, {_, guest_view}] = views
    assert MapSet.disjoint?(MapSet.new(host_view["my_hints"]), MapSet.new(guest_view["my_hints"]))
    refute Jason.encode!(host_view) =~ Jason.encode!(hd(guest_view["my_hints"]))

    state = engine(host_view["id"])
    current = host_view["current_player"]
    other = Enum.find([host, guest], &(&1 != current))

    assert %{"error" => "not_your_turn"} =
             api(:post, "/api/lobbies/#{id}/attempts", other, %{sequence: state.secret})
             |> json_response(409)

    assert %{"error" => "invalid", "errors" => %{"sequence" => _}} =
             api(:post, "/api/lobbies/#{id}/attempts", current, %{sequence: [0, 0, 1, 2, 3]})
             |> json_response(422)

    assert %{
             "match" => %{
               "status" => "won",
               "secret" => secret,
               "attempts" => [%{"marks" => marks}]
             }
           } =
             api(:post, "/api/lobbies/#{id}/attempts", current, %{sequence: state.secret})
             |> json_response(200)

    assert secret == state.secret and marks == List.duplicate("hit", 5)

    assert %{"match" => %{"my_reward" => %{"amount" => 50, "status" => "pending"}}} =
             api(:get, "/api/lobbies/#{id}", other) |> json_response(200)
  end

  test "codes d'erreur : 409 plein, 410 lien expiré, 429 chat, 422 validation, 503 social" do
    host = uuid()
    lobby = lobby!(host, %{"max_players" => 2})
    join!(lobby, uuid())
    base = "/api/lobbies/#{lobby.id}"

    assert %{"error" => "full"} = api(:post, base <> "/join", uuid()) |> json_response(409)

    {:ok, _, token} =
      Invitations.create_link(
        host,
        lobby.id,
        %{"expires_in_minutes" => 5},
        DateTime.add(DateTime.utc_now(), -600)
      )

    assert %{"error" => "expired"} =
             api(:post, "/api/links/preview", uuid(), %{token: token}) |> json_response(410)

    refute api(:post, "/api/links/preview", uuid(), %{token: token}).resp_body =~ lobby.title

    assert %{"error" => "not_found"} =
             api(:post, "/api/links/join", uuid(), %{token: "nope"}) |> json_response(404)

    for i <- 1..5,
        do: assert(api(:post, base <> "/messages", host, %{body: "m#{i}"}).status == 201)

    assert %{"error" => "rate_limited"} =
             api(:post, base <> "/messages", host, %{body: "x"}) |> json_response(429)

    assert %{"error" => "invalid", "errors" => %{"title" => _}} =
             api(:post, "/api/lobbies", uuid(), %{title: "", visibility: "open", max_players: 2})
             |> json_response(422)

    stub_services(social: :down)

    assert %{"error" => "social_unavailable"} =
             api(:post, "/api/lobbies/#{lobby!(uuid()).id}/join", uuid()) |> json_response(503)
  end

  test "outils de l'hôte : le jeton de lien n'est rendu qu'à la création, jamais dans la vue" do
    host = uuid()
    lobby = lobby!(host, %{"visibility" => "private"})
    base = "/api/lobbies/#{lobby.id}"

    assert %{"link" => %{"id" => link_id, "token" => token, "state" => "active", "max_uses" => 3}} =
             api(:post, base <> "/links", host, %{max_uses: 3, expires_in_minutes: 30})
             |> json_response(201)

    detail = api(:get, base, host) |> json_response(200)
    assert [%{"id" => ^link_id, "uses" => 0}] = detail["links"]
    refute Jason.encode!(detail) =~ token

    assert api(:delete, base <> "/links/#{link_id}", host).status == 204

    assert %{"error" => "revoked"} =
             api(:post, "/api/links/preview", uuid(), %{token: token}) |> json_response(410)
  end

  test "invitations par l'API : liste de l'invité enrichie, acceptation" do
    host = uuid()
    lobby = lobby!(host, %{"visibility" => "private"})
    friend = uuid()

    assert %{"invite" => %{"id" => invite_id, "invitee" => %{"id" => ^friend}}} =
             api(:post, "/api/lobbies/#{lobby.id}/invites", host, %{user_id: friend})
             |> json_response(201)

    assert %{
             "invites" => [
               %{
                 "id" => ^invite_id,
                 "inviter" => %{"id" => ^host},
                 "lobby" => %{"title" => "Rune night"}
               }
             ]
           } =
             api(:get, "/api/me/invites", friend) |> json_response(200)

    assert %{"error" => "not_found"} =
             api(:post, "/api/invites/#{invite_id}/accept", uuid()) |> json_response(404)

    lobby_id = lobby.id

    assert %{"lobby_id" => ^lobby_id} =
             api(:post, "/api/invites/#{invite_id}/accept", friend) |> json_response(200)

    assert %{"role" => "player"} =
             api(:get, "/api/lobbies/#{lobby.id}", friend) |> json_response(200)
  end

  test "invitation refusée par le réglage de l'invité : 403 lobby_invites_closed (décision de social)" do
    host = uuid()
    lobby = lobby!(host)
    friend = uuid()
    stub_services(invites_closed: [friend])

    assert %{"error" => "lobby_invites_closed"} =
             api(:post, "/api/lobbies/#{lobby.id}/invites", host, %{user_id: friend})
             |> json_response(403)

    assert_received {:service, "GET", "/api/internal/can-contact", nil}
    assert %{"invites" => []} = api(:get, "/api/me/invites", friend) |> json_response(200)
  end
end
