defmodule MlMultiplayerWeb.PrivacyTest do
  use MlMultiplayerWeb.ConnCase, async: false
  alias MlMultiplayer.{Invitations, Invite, Lobbies, Lobby, Link, Member, Message, Reward}

  defp caller(service, user_id \\ nil) do
    put_req_header(
      build_conn(),
      "authorization",
      "Bearer " <> MlShared.InternalToken.sign(service, user_id)
    )
  end

  defp export(user_id),
    do: caller("accounts") |> get("/api/internal/users/#{user_id}/export") |> json_response(200)

  defp message!(lobby, user_id, body),
    do: Repo.insert!(%Message{lobby_id: lobby.id, user_id: user_id, body: body})

  setup do
    [me, other, guest] = for _ <- 1..3, do: uuid()
    lobby = lobby!(me, %{"title" => "Moonlit relay"})
    join!(lobby, other)
    message!(lobby, me, "Ready when you are")
    message!(lobby, other, "A message from another player")
    {:ok, _invite} = Invitations.invite(me, lobby.id, guest)
    {:ok, _link, _token} = Invitations.create_link(me, lobby.id, %{})
    %{me: me, other: other, guest: guest, lobby: lobby}
  end

  test "only the accounts service may call them (403 otherwise)", %{me: me} do
    for conn <- [caller("web", me), caller("social"), caller("studio")] do
      assert %{"error" => "forbidden"} =
               conn |> get("/api/internal/users/#{me}/export") |> json_response(403)

      assert conn |> recycle() |> delete("/api/internal/users/#{me}") |> json_response(403)
    end

    assert Repo.aggregate(Invite, :count) == 1
  end

  test "export: own lobbies, invitations, links and messages, never the others' messages", %{
    me: me,
    guest: guest,
    lobby: lobby
  } do
    assert %{"data" => data} = export(me)
    lobby_id = lobby.id

    assert [%{"lobby_id" => ^lobby_id, "host" => true, "membership" => "active"}] =
             data["lobbies"]

    assert [%{"id" => ^lobby_id, "title" => "Moonlit relay"}] = data["hosted_lobbies"]
    assert [%{"body" => "Ready when you are"}] = data["messages_sent"]
    assert [%{"invitee_id" => ^guest, "inviter_id" => ^me}] = data["invites"]
    assert [%{"max_uses" => 5, "uses" => 0}] = data["links_created"]
    refute inspect(data) =~ "another player"

    assert caller("accounts") |> get("/api/internal/users/nope/export") |> json_response(404)
  end

  test "export of a game: the member's attempts and matches, never the secret or the hints" do
    %{lobby: lobby, match: match} = playing!(2)
    %{secret: secret, players: [first, second]} = engine(match.id)
    {:ok, _} = Lobbies.attempt(first, lobby.id, wrong_guess(secret))

    assert %{"data" => data} = export(first)
    match_id = match.id
    assert [%{"id" => ^match_id, "status" => "active"}] = data["matches"]

    assert [%{"match_id" => ^match_id, "sequence" => sequence, "marks" => [_, _, _, _, _]}] =
             data["attempts"]

    assert sequence == wrong_guess(secret)
    refute inspect(data) =~ "hints"
    refute inspect(data) =~ "secret"

    assert %{"data" => %{"attempts" => [], "matches" => [%{"id" => ^match_id}]}} = export(second)
  end

  test "DELETE: leaves the lobby (host handed over), removes invitations, links, rewards; keeps messages; idempotent",
       %{me: me, other: other, lobby: lobby} do
    %{match: match} = playing!(2)

    Repo.insert!(%Reward{
      match_id: match.id,
      user_id: me,
      amount: 50,
      next_attempt_at: DateTime.utc_now()
    })

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)

    assert %Lobby{host_id: ^other, status: "waiting"} = Repo.get!(Lobby, lobby.id)
    assert %Member{status: "left"} = Repo.get_by!(Member, lobby_id: lobby.id, user_id: me)
    assert Repo.aggregate(Invite, :count) == 0
    assert Repo.aggregate(Link, :count) == 0
    assert Repo.all(from r in Reward, where: r.user_id == ^me) == []

    # messages conservés, toujours rattachés à l'identifiant du membre
    assert %{"entries" => entries} =
             api("GET", "/api/lobbies/#{lobby.id}/messages", other) |> json_response(200)

    assert Enum.map(entries, & &1["user_id"]) == [me, other]

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
    assert %{"data" => %{"invites" => [], "rewards" => []}} = export(me)
  end
end
