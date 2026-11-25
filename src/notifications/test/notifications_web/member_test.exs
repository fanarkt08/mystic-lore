defmodule MlNotificationsWeb.MemberTest do
  use MlNotificationsWeb.ConnCase, async: true
  alias MlNotifications.Notification

  defp page(me, query \\ ""),
    do: api(:get, "/api/me/notifications" <> query, me) |> json_response(200)

  test "list: newest first, actor identities from accounts, cursor pages, unread filter" do
    me = uuid()
    t0 = ~U[2026-11-20 08:00:00.000000Z]

    ids =
      for i <- 1..25 do
        %{notification: n} =
          create!(attrs("friend_request_received", me), DateTime.add(t0, i, :minute))

        n.id
      end

    # someone else's notifications never show
    create!(attrs("badge_earned", uuid()))

    first = page(me)
    assert length(first["entries"]) == 20
    assert first["unread"] == 25
    assert Enum.map(first["entries"], & &1["id"]) == ids |> Enum.reverse() |> Enum.take(20)

    [entry | _] = first["entries"]

    assert %{"kind" => "friend_request_received", "category" => "friends", "read" => false} =
             entry

    assert %{"display_name" => "User " <> _, "username" => "user_" <> _} = entry["actor"]
    assert entry["actor"]["id"] == entry["actor_id"]
    assert %{"type" => "member"} = entry["subject"]

    second = page(me, "?before=#{first["next_before"]}")
    assert Enum.map(second["entries"], & &1["id"]) == ids |> Enum.reverse() |> Enum.drop(20)
    assert second["next_before"] == nil

    Repo.update_all(where(Notification, [n], n.id in ^Enum.take(ids, 20)), set: [read_at: t0])
    unread = page(me, "?filter=unread&limit=3")
    assert Enum.map(unread["entries"], & &1["id"]) == ids |> Enum.reverse() |> Enum.take(3)
    assert unread["unread"] == 5

    assert %{"errors" => %{"before" => ["is invalid"]}} =
             api(:get, "/api/me/notifications?before=nonsense", me) |> json_response(422)
  end

  test "accounts unreachable: the list is still served, actors are null" do
    me = uuid()
    create!(attrs("community_reply", me))
    Req.Test.stub(MlShared.Client, &Req.Test.transport_error(&1, :econnrefused))
    assert %{"entries" => [%{"actor" => nil, "actor_id" => id}]} = page(me)
    assert is_binary(id)
  end

  test "unread count, show, read one (idempotent), read all" do
    me = uuid()
    %{notification: a} = create!(attrs("badge_earned", me))
    %{notification: b} = create!(attrs("lobby_invite", me))

    assert %{"unread" => 2} =
             api(:get, "/api/me/notifications/unread-count", me) |> json_response(200)

    assert %{"notification" => %{"id" => id, "read" => false}} =
             api(:get, "/api/me/notifications/#{a.id}", me) |> json_response(200)

    assert id == a.id

    MlShared.Events.subscribe("user:#{me}")

    for _ <- 1..2 do
      assert %{"notification" => %{"read" => true, "read_at" => at}} =
               api(:post, "/api/me/notifications/#{a.id}/read", me) |> json_response(200)

      assert is_binary(at)
    end

    # one event only: the second read changed nothing
    assert_receive {:notifications_changed, ^me, nil}
    refute_receive {:notifications_changed, ^me, _}

    assert %{"unread" => 1} =
             api(:get, "/api/me/notifications/unread-count", me) |> json_response(200)

    assert %{"read" => 1, "unread" => 0} =
             api(:post, "/api/me/notifications/read-all", me) |> json_response(200)

    assert Repo.get!(Notification, b.id).read_at
  end

  test "another member's notification is not found (no IDOR), nor a malformed id" do
    me = uuid()
    %{notification: theirs} = create!(attrs("badge_earned", uuid()))

    for path <- ["/api/me/notifications/#{theirs.id}", "/api/me/notifications/nope"] do
      assert %{"error" => "not_found"} = api(:get, path, me) |> json_response(404)
    end

    assert %{"error" => "not_found"} =
             api(:post, "/api/me/notifications/#{theirs.id}/read", me) |> json_response(404)

    refute Repo.get!(Notification, theirs.id).read_at
    assert %{"read" => 0} = api(:post, "/api/me/notifications/read-all", me) |> json_response(200)
    refute Repo.get!(Notification, theirs.id).read_at
  end

  test "member routes need a member in the token; the id comes from the token only" do
    conn = service(:get, "/api/me/notifications", "web")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}

    conn = api(:get, "/api/me/notifications", "not-a-uuid")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "health check" do
    assert %{"status" => "ok"} = build_conn() |> get("/healthz") |> json_response(200)
  end
end
