defmodule MlSocialWeb.FriendControllerTest do
  use MlSocialWeb.ConnCase, async: true
  alias MlShared.Events
  alias MlSocial.{Friends, Friendship, Repo}

  setup do
    {:ok, a: uuid(), b: uuid(), c: uuid()}
  end

  defp request(from, to), do: api(:post, "/api/friend-requests", from, %{user_id: to})
  defp friends_of(user), do: api(:get, "/api/me/friends", user) |> json_response(200)
  defp requests_of(user), do: api(:get, "/api/me/friend-requests", user) |> json_response(200)

  describe "demandes d'ami" do
    test "envoi, doublon, acceptation mutuelle sur demande inverse, puis déjà amis", %{a: a, b: b} do
      assert %{"id" => id, "status" => "pending"} = request(a, b) |> json_response(201)
      assert %{"error" => "already_requested"} = request(a, b) |> json_response(409)

      assert %{"id" => ^id, "status" => "accepted"} = request(b, a) |> json_response(200)
      assert %{"error" => "already_friends"} = request(a, b) |> json_response(409)
      assert %{"error" => "already_friends"} = request(b, a) |> json_response(409)

      assert %{"friends" => [%{"id" => ^b, "display_name" => "User " <> _}]} = friends_of(a)
      assert %{"friends" => [%{"id" => ^a, "username" => "user_" <> _}]} = friends_of(b)
    end

    test "auto-demande et identifiant invalide refusés", %{a: a} do
      assert %{"error" => "self"} = request(a, a) |> json_response(422)

      for bad <- ["nope", nil, 42] do
        assert %{"error" => "invalid", "errors" => %{"user_id" => ["is invalid"]}} =
                 request(a, bad) |> json_response(422)
      end
    end

    test "seul le destinataire accepte ; l'acceptation est idempotente", %{a: a, b: b, c: c} do
      %{"id" => id} = request(a, b) |> json_response(201)

      for user <- [c, a] do
        assert %{"error" => "not_found"} =
                 api(:post, "/api/friend-requests/#{id}/accept", user) |> json_response(404)
      end

      assert api(:post, "/api/friend-requests/not-a-uuid/accept", b) |> json_response(404)
      refute Friends.friends?(a, b)

      assert %{"id" => ^id, "status" => "accepted"} =
               api(:post, "/api/friend-requests/#{id}/accept", b) |> json_response(200)

      assert %{"status" => "accepted"} =
               api(:post, "/api/friend-requests/#{id}/accept", b) |> json_response(200)

      assert Friends.friends?(a, b)
    end

    test "listes enrichies, refus par le destinataire, annulation par l'émetteur", %{
      a: a,
      b: b,
      c: c
    } do
      %{"id" => ab} = request(a, b) |> json_response(201)
      %{"id" => cb} = request(c, b) |> json_response(201)

      assert %{"incoming" => incoming, "outgoing" => []} = requests_of(b)

      assert incoming |> Enum.map(&{&1["id"], &1["from"]["id"]}) |> Enum.sort() ==
               Enum.sort([{ab, a}, {cb, c}])

      assert %{"incoming" => [], "outgoing" => [%{"id" => ^ab, "to" => %{"id" => ^b} = to}]} =
               requests_of(a)

      assert to == fake_user(b)

      assert %{"messages" => 0, "friend_requests" => 2} =
               api(:get, "/api/me/unread", b) |> json_response(200)

      # un tiers ne peut ni refuser ni annuler
      assert api(:post, "/api/friend-requests/#{ab}/decline", c) |> json_response(404)
      assert api(:post, "/api/friend-requests/#{ab}/decline", b) |> response(204)
      assert api(:post, "/api/friend-requests/#{cb}/decline", c) |> response(204)
      assert api(:post, "/api/friend-requests/#{cb}/decline", c) |> json_response(404)

      assert %{"incoming" => [], "outgoing" => []} = requests_of(b)
      assert %{"friend_requests" => 0} = api(:get, "/api/me/unread", b) |> json_response(200)
      # une demande refusée peut être renvoyée
      assert request(a, b) |> json_response(201)
    end

    test "on ne refuse pas une amitié déjà acceptée", %{a: a, b: b} do
      %{id: id} = befriend(a, b)
      assert api(:post, "/api/friend-requests/#{id}/decline", b) |> json_response(404)
      assert Friends.friends?(a, b)
    end

    test "retrait d'ami (idempotent) des deux côtés", %{a: a, b: b} do
      befriend(a, b)
      assert api(:delete, "/api/friends/#{b}", a) |> response(204)
      assert api(:delete, "/api/friends/#{b}", a) |> response(204)
      assert %{"friends" => []} = friends_of(a)
      assert %{"friends" => []} = friends_of(b)
      assert request(b, a) |> json_response(201)
    end

    test "friendship_changed est publié aux deux membres", %{a: a, b: b} do
      Events.subscribe(Events.user(a))
      Events.subscribe(Events.user(b))

      %{"id" => id} = request(a, b) |> json_response(201)
      assert_receive {:friendship_changed, ^a}
      assert_receive {:friendship_changed, ^b}
      assert_receive {:unread_changed, ^b}

      api(:post, "/api/friend-requests/#{id}/accept", b) |> json_response(200)
      assert_receive {:friendship_changed, ^a}
      assert_receive {:friendship_changed, ^b}

      api(:delete, "/api/friends/#{a}", b) |> response(204)
      assert_receive {:friendship_changed, ^a}
      assert_receive {:friendship_changed, ^b}
    end

    test "la paire non ordonnée est unique en base, dans les deux sens", %{a: a, b: b} do
      Repo.insert!(%Friendship{requester_id: a, addressee_id: b})

      assert_raise Ecto.ConstraintError, ~r/friendships_pair_index/, fn ->
        Repo.insert!(%Friendship{requester_id: b, addressee_id: a})
      end
    end
  end

  describe "blocages" do
    test "bloquer supprime l'amitié et empêche les demandes dans les deux sens", %{a: a, b: b} do
      befriend(a, b)
      Events.subscribe(Events.user(b))

      assert api(:post, "/api/blocks", a, %{user_id: b}) |> response(204)
      assert_receive {:friendship_changed, ^b}
      assert api(:post, "/api/blocks", a, %{user_id: b}) |> response(204)

      assert %{"friends" => []} = friends_of(a)
      assert %{"friends" => []} = friends_of(b)
      assert %{"error" => "blocked"} = request(b, a) |> json_response(403)
      assert %{"error" => "blocked"} = request(a, b) |> json_response(403)

      assert %{"blocks" => [%{"id" => ^b, "display_name" => "User " <> _}]} =
               api(:get, "/api/me/blocks", a) |> json_response(200)

      assert %{"blocks" => []} = api(:get, "/api/me/blocks", b) |> json_response(200)
    end

    test "bloquer supprime les demandes en attente", %{a: a, b: b} do
      request(b, a) |> json_response(201)
      assert api(:post, "/api/blocks", a, %{user_id: b}) |> response(204)
      assert %{"incoming" => [], "outgoing" => []} = requests_of(a)
      assert %{"incoming" => [], "outgoing" => []} = requests_of(b)
      assert %{"friend_requests" => 0} = api(:get, "/api/me/unread", a) |> json_response(200)
    end

    test "seul le bloqueur lève le blocage ; l'amitié n'est pas rétablie", %{a: a, b: b} do
      befriend(a, b)
      api(:post, "/api/blocks", a, %{user_id: b}) |> response(204)

      assert api(:delete, "/api/blocks/#{a}", b) |> response(204)
      assert Friends.blocked?(a, b)

      assert api(:delete, "/api/blocks/#{b}", a) |> response(204)
      assert api(:delete, "/api/blocks/#{b}", a) |> response(204)
      refute Friends.blocked?(a, b)
      refute Friends.friends?(a, b)
      assert request(b, a) |> json_response(201)
    end

    test "on ne se bloque pas soi-même", %{a: a} do
      assert %{"error" => "self"} =
               api(:post, "/api/blocks", a, %{user_id: a}) |> json_response(422)

      assert %{"error" => "invalid"} =
               api(:post, "/api/blocks", a, %{user_id: "x"}) |> json_response(422)
    end
  end
end
