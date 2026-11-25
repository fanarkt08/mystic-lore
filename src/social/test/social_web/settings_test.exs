defmodule MlSocialWeb.SettingsTest do
  @moduledoc "Réglages de confidentialité et permissions de contact (décidées par social, côté serveur)."
  use MlSocialWeb.ConnCase, async: true
  alias MlShared.Events

  setup do
    {:ok, a: uuid(), b: uuid(), c: uuid()}
  end

  defp settings(user), do: api(:get, "/api/me/settings", user) |> json_response(200)
  defp save(user, body), do: api(:patch, "/api/me/settings", user, body)
  defp request(from, to), do: api(:post, "/api/friend-requests", from, %{user_id: to})

  defp can_contact(params) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign("multiplayer"))
    |> get("/api/internal/can-contact?" <> URI.encode_query(params))
  end

  test "valeurs par défaut, changement partiel, valeurs refusées à côté du champ", %{a: a} do
    assert %{
             "settings" => %{
               "show_online" => true,
               "read_receipts" => true,
               "friend_requests" => "everyone",
               "group_adds" => "friends",
               "lobby_invites" => "friends"
             }
           } = settings(a)

    assert %{"settings" => %{"friend_requests" => "nobody", "show_online" => true}} =
             save(a, %{friend_requests: "nobody"}) |> json_response(200)

    assert %{"settings" => %{"friend_requests" => "nobody", "show_online" => false}} =
             save(a, %{show_online: false}) |> json_response(200)

    assert %{"errors" => errors} =
             save(a, %{
               friend_requests: "friends",
               group_adds: "everyone",
               lobby_invites: nil,
               read_receipts: "maybe"
             })
             |> json_response(422)

    assert Map.keys(errors) |> Enum.sort() ==
             ~w(friend_requests group_adds lobby_invites read_receipts)

    assert %{"settings" => %{"friend_requests" => "nobody"}} = settings(a)
  end

  describe "demandes d'ami" do
    test "« personne » : 403 friend_requests_closed ; une demande inverse reste acceptable", %{
      a: a,
      b: b
    } do
      setting!(b, %{"friend_requests" => "nobody"})
      assert %{"error" => "friend_requests_closed"} = request(a, b) |> json_response(403)

      # b a lui-même demandé : a peut accepter (acceptation mutuelle)
      %{"id" => _} = request(b, a) |> json_response(201)
      assert %{"status" => "accepted"} = request(a, b) |> json_response(200)
    end

    test "« amis d'amis » : seulement avec un ami commun", %{a: a, b: b, c: c} do
      setting!(b, %{"friend_requests" => "friends_of_friends"})
      assert %{"error" => "friend_requests_closed"} = request(a, b) |> json_response(403)

      # c, ami des deux (les demandes vont vers c et a, qui acceptent tout le monde)
      befriend(b, c)
      befriend(c, a)
      assert %{"status" => "pending"} = request(a, b) |> json_response(201)
    end

    test "un blocage reste annoncé comme tel (avant la permission)", %{a: a, b: b} do
      setting!(b, %{"friend_requests" => "nobody"})
      api(:post, "/api/blocks", b, %{user_id: a}) |> response(204)
      assert %{"error" => "blocked"} = request(a, b) |> json_response(403)
    end
  end

  describe "route interne can-contact (multiplayer, avant une invitation)" do
    test "invitation de salon : amis seulement, sauf réglage « personne »", %{a: a, b: b, c: c} do
      befriend(a, b)
      kind = "lobby_invite"

      assert %{"allowed" => true} =
               can_contact(from: a, to: b, kind: kind) |> json_response(200)

      assert %{"error" => "not_friends"} =
               can_contact(from: a, to: c, kind: kind) |> json_response(403)

      setting!(b, %{"lobby_invites" => "nobody"})

      assert %{"error" => "lobby_invites_closed"} =
               can_contact(from: a, to: b, kind: kind) |> json_response(403)

      api(:post, "/api/blocks", c, %{user_id: a}) |> response(204)

      assert %{"error" => "blocked"} =
               can_contact(from: a, to: c, kind: kind) |> json_response(403)

      assert %{"error" => "self"} =
               can_contact(from: a, to: a, kind: kind) |> json_response(403)
    end

    test "ajout en groupe et demande d'ami ; paramètres invalides 422 ; jeton exigé", %{
      a: a,
      b: b
    } do
      befriend(a, b)
      setting!(b, %{"group_adds" => "nobody"})

      assert %{"error" => "group_adds_closed"} =
               can_contact(from: a, to: b, kind: "group_add") |> json_response(403)

      assert %{"allowed" => true} =
               can_contact(from: b, to: a, kind: "friend_request") |> json_response(200)

      for params <- [
            [from: a, to: b, kind: "hug"],
            [from: "x", to: b, kind: "group_add"],
            [from: a]
          ] do
        assert %{"error" => "invalid"} = can_contact(params) |> json_response(422)
      end

      assert build_conn()
             |> get("/api/internal/can-contact?from=#{a}&to=#{b}&kind=group_add")
             |> json_response(401)
    end
  end

  describe "visibilité" do
    test "les amis voient online_visible ; le changer prévient chaque ami", %{a: a, b: b, c: c} do
      befriend(a, b)
      befriend(a, c)
      Events.subscribe(Events.user(b))
      Events.subscribe(Events.user(a))

      assert %{"friends" => [%{"online_visible" => true}]} =
               api(:get, "/api/me/friends", b) |> json_response(200)

      save(a, %{show_online: false}) |> json_response(200)
      assert_receive {:social_settings_changed, ^a}
      assert_receive {:friendship_changed, ^b}

      assert %{"friends" => [%{"id" => ^a, "online_visible" => false}]} =
               api(:get, "/api/me/friends", b) |> json_response(200)

      # rien ne change : aucun événement pour les amis
      save(a, %{show_online: false}) |> json_response(200)
      refute_receive {:friendship_changed, ^b}, 50
    end
  end
end
