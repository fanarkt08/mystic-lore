defmodule MlSocialWeb.ConversationControllerTest do
  use MlSocialWeb.ConnCase, async: true
  import Ecto.Query
  alias MlShared.Events
  alias MlSocial.{Chat, Conversation, Member, Repo}

  setup do
    {:ok, a: uuid(), b: uuid(), c: uuid()}
  end

  defp messages_path(conversation), do: "/api/conversations/#{conversation.id}/messages"

  defp say(conversation, user, body),
    do: api(:post, messages_path(conversation), user, %{body: body})

  defp bodies(page), do: Enum.map(page["entries"], & &1["body"])

  describe "ouverture" do
    test "réservée aux amis, unique par paire et idempotente", %{a: a, b: b} do
      assert %{"error" => "not_friends"} =
               api(:post, "/api/conversations", a, %{user_id: b}) |> json_response(403)

      assert %{"error" => "not_friends"} =
               api(:post, "/api/conversations", a, %{user_id: a}) |> json_response(403)

      assert %{"error" => "invalid", "errors" => %{"user_id" => _}} =
               api(:post, "/api/conversations", a, %{user_id: "x"}) |> json_response(422)

      befriend(a, b)

      assert %{
               "conversation" => %{
                 "id" => id,
                 "other" => other,
                 "last_message" => nil,
                 "unread" => 0
               }
             } =
               api(:post, "/api/conversations", a, %{user_id: b}) |> json_response(200)

      assert other == fake_user(b)

      assert %{"conversation" => %{"id" => ^id, "other" => %{"id" => ^a}}} =
               api(:post, "/api/conversations", b, %{user_id: a}) |> json_response(200)

      assert %{"conversation" => %{"id" => ^id}} =
               api(:get, "/api/conversations/#{id}", b) |> json_response(200)

      assert Repo.aggregate(from(c in Conversation, where: c.id == ^id), :count) == 1
      assert Repo.aggregate(from(m in Member, where: m.conversation_id == ^id), :count) == 2
    end

    test "un non-membre reçoit 404 sur toute route de conversation (comme un id inexistant)", %{
      a: a,
      b: b,
      c: c
    } do
      conversation = conversation_between(a, b)
      insert_messages(conversation, [{a, "secret", 10}])
      # amie de a, mais pas membre de cette conversation
      befriend(a, c)

      for id <- [conversation.id, uuid(), "not-a-uuid"] do
        assert %{"error" => "not_found"} =
                 api(:get, "/api/conversations/#{id}", c) |> json_response(404)

        assert %{"error" => "not_found"} =
                 api(:get, "/api/conversations/#{id}/messages", c) |> json_response(404)

        for body <- ["hi", ""] do
          assert %{"error" => "not_found"} =
                   api(:post, "/api/conversations/#{id}/messages", c, %{body: body})
                   |> json_response(404)
        end

        assert %{"error" => "not_found"} =
                 api(:post, "/api/conversations/#{id}/read", c) |> json_response(404)
      end

      assert %{"conversations" => []} =
               api(:get, "/api/me/conversations", c) |> json_response(200)

      assert %{"messages" => 0} = api(:get, "/api/me/unread", c) |> json_response(200)
    end
  end

  describe "messages" do
    test "envoi : corps nettoyé, 1 à 2000 caractères", %{a: a, b: b} do
      conversation = conversation_between(a, b)

      assert %{"message" => message} = say(conversation, a, "  Hello \n") |> json_response(201)

      assert %{
               "conversation_id" => cid,
               "sender_id" => ^a,
               "body" => "Hello",
               "inserted_at" => at
             } = message

      assert Map.keys(message) |> Enum.sort() ==
               ~w(attachment body conversation_id hidden id inserted_at kind removed sender_id system)

      assert %{"kind" => "text", "hidden" => false, "attachment" => nil, "system" => nil} =
               message

      assert cid == conversation.id
      assert {:ok, _, 0} = DateTime.from_iso8601(at)

      for body <- ["", "   \n ", nil, 42] do
        assert %{"error" => "invalid", "errors" => %{"body" => [_]}} =
                 say(conversation, a, body) |> json_response(422)
      end

      assert %{"errors" => %{"body" => ["should be at most 2000 character(s)"]}} =
               say(conversation, a, String.duplicate("é", 2001)) |> json_response(422)

      assert %{"message" => %{"body" => long}} =
               say(conversation, a, String.duplicate("é", 2000)) |> json_response(201)

      assert String.length(long) == 2000

      assert %{"errors" => %{"body" => ["is invalid"]}} =
               say(conversation, a, "a" <> <<0>> <> "b") |> json_response(422)

      assert %{"entries" => [%{"body" => "Hello"}, %{"body" => ^long}]} =
               api(:get, messages_path(conversation), b) |> json_response(200)
    end

    test "pagination par curseur : 30 par page, ordre chronologique", %{a: a, b: b, c: c} do
      conversation = conversation_between(a, b)
      insert_messages(conversation, for(i <- 1..65, do: {Enum.random([a, b]), "m#{i}", 1000 - i}))
      path = messages_path(conversation)

      page1 = api(:get, path, a) |> json_response(200)
      assert bodies(page1) == Enum.map(36..65, &"m#{&1}")
      assert page1["next_before"] == hd(page1["entries"])["id"]

      page2 = api(:get, path <> "?before=#{page1["next_before"]}", b) |> json_response(200)
      assert bodies(page2) == Enum.map(6..35, &"m#{&1}")

      page3 = api(:get, path <> "?before=#{page2["next_before"]}", a) |> json_response(200)
      assert bodies(page3) == Enum.map(1..5, &"m#{&1}")
      assert page3["next_before"] == nil

      # un curseur d'une autre conversation (ou inconnu) est refusé
      other = conversation_between(a, c)
      [%{id: foreign}] = insert_messages(other, [{c, "ailleurs", 1}])

      for cursor <- [foreign, uuid(), "x"] do
        assert %{"errors" => %{"before" => ["is invalid"]}} =
                 api(:get, path <> "?before=#{cursor}", a) |> json_response(422)
      end
    end

    test "pagination stable à horodatage égal ; exactement 30 messages → pas de page suivante", %{
      a: a,
      b: b
    } do
      conversation = conversation_between(a, b)
      insert_messages(conversation, for(i <- 1..30, do: {a, "s#{i}", 60}))
      path = messages_path(conversation)

      assert %{"entries" => entries, "next_before" => nil} =
               api(:get, path, a) |> json_response(200)

      assert length(entries) == 30

      insert_messages(conversation, for(i <- 31..35, do: {b, "s#{i}", 60}))
      page1 = api(:get, path, a) |> json_response(200)
      page2 = api(:get, path <> "?before=#{page1["next_before"]}", a) |> json_response(200)
      assert length(page2["entries"]) == 5
      assert page2["next_before"] == nil

      all = Enum.map(page2["entries"] ++ page1["entries"], & &1["id"])
      assert length(Enum.uniq(all)) == 35
    end

    test "blocage : refuse l'ouverture et l'envoi, même dans une conversation existante", %{
      a: a,
      b: b
    } do
      conversation = conversation_between(a, b)
      assert say(conversation, b, "avant") |> json_response(201)

      api(:post, "/api/blocks", a, %{user_id: b}) |> response(204)
      assert %{"error" => "blocked"} = say(conversation, b, "après") |> json_response(403)
      assert %{"error" => "blocked"} = say(conversation, a, "après") |> json_response(403)

      assert %{"error" => "blocked"} =
               api(:post, "/api/conversations", b, %{user_id: a}) |> json_response(403)

      # l'historique reste lisible par ses membres
      assert %{"entries" => [%{"body" => "avant"}]} =
               api(:get, messages_path(conversation), b) |> json_response(200)

      # débloquer ne rétablit pas l'amitié : toujours refusé
      api(:delete, "/api/blocks/#{b}", a) |> response(204)
      assert %{"error" => "not_friends"} = say(conversation, b, "après") |> json_response(403)
    end

    test "retrait d'ami : l'envoi suivant est refusé", %{a: a, b: b} do
      conversation = conversation_between(a, b)
      assert say(conversation, a, "un") |> json_response(201)
      api(:delete, "/api/friends/#{a}", b) |> response(204)
      assert %{"error" => "not_friends"} = say(conversation, a, "deux") |> json_response(403)
    end

    test "événements livrés par membre : new_message à chacun (expéditeur compris), unread_changed au destinataire",
         %{a: a, b: b, c: c} do
      conversation = conversation_between(a, b)
      for user <- [a, b, c], do: Events.subscribe(Events.user(user))

      %{"message" => message} = say(conversation, a, "Salut") |> json_response(201)
      # une copie par membre (le test est abonné aux deux topics), aucune pour un non-membre
      assert_receive {:new_message, ^message}
      assert_receive {:new_message, ^message}
      refute_receive {:new_message, _}, 50
      assert_received {:unread_changed, ^b}
      refute_received {:unread_changed, ^a}
      refute_received {:unread_changed, ^c}

      api(:post, "/api/conversations/#{conversation.id}/read", b) |> response(204)
      assert_receive {:unread_changed, ^b}

      # un envoi refusé ne publie rien
      api(:post, "/api/blocks", b, %{user_id: a}) |> response(204)
      assert say(conversation, a, "refusé") |> json_response(403)
      refute_received {:new_message, _}
    end
  end

  describe "non-lus et lecture" do
    test "messages des autres postérieurs à la dernière lecture + demandes entrantes", %{
      a: a,
      b: b,
      c: c
    } do
      ab = conversation_between(a, b)
      ac = conversation_between(a, c)
      for body <- ["un", "deux"], do: say(ab, b, body) |> json_response(201)
      say(ac, c, "trois") |> json_response(201)
      say(ab, a, "à moi") |> json_response(201)
      api(:post, "/api/friend-requests", uuid(), %{user_id: a}) |> json_response(201)

      assert %{"messages" => 3, "friend_requests" => 1} =
               api(:get, "/api/me/unread", a) |> json_response(200)

      assert %{"messages" => 1, "friend_requests" => 0} =
               api(:get, "/api/me/unread", b) |> json_response(200)

      # tri par dernier message
      assert %{"conversations" => [first, second]} =
               api(:get, "/api/me/conversations", a) |> json_response(200)

      ab_id = ab.id
      ac_id = ac.id

      assert %{"id" => ^ab_id, "unread" => 2, "other" => %{"id" => ^b}} = first

      assert %{"body" => "à moi", "sender_id" => ^a, "conversation_id" => ^ab_id} =
               first["last_message"]

      assert %{"id" => ^ac_id, "unread" => 1, "last_message" => %{"body" => "trois"}} = second

      assert api(:post, "/api/conversations/#{ab.id}/read", a) |> response(204)
      assert %{"messages" => 1} = api(:get, "/api/me/unread", a) |> json_response(200)

      assert %{"conversation" => %{"unread" => 0}} =
               api(:get, "/api/conversations/#{ab.id}", a) |> json_response(200)

      say(ab, b, "nouveau") |> json_response(201)
      assert %{"messages" => 2} = api(:get, "/api/me/unread", a) |> json_response(200)
    end
  end

  describe "enrichissement via accounts" do
    test "une seule requête accounts par réponse, quel que soit le nombre de membres", %{a: a} do
      friends = for _ <- 1..3, do: uuid()
      Enum.each(friends, &befriend(a, &1))
      Enum.each(friends, &({:ok, _} = Chat.open(a, &1)))

      test = self()

      Req.Test.stub(MlShared.Client, fn conn ->
        send(test, {:accounts, conn.method, conn.request_path, conn.query_params["ids"]})
        fake_accounts(conn)
      end)

      %{"friends" => listed} = api(:get, "/api/me/friends", a) |> json_response(200)
      assert listed |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort(friends)

      assert Enum.all?(
               listed,
               &(&1 == Map.put(fake_user(&1["id"]), "online_visible", true))
             )

      assert_received {:accounts, "GET", "/api/users", ids}
      assert ids |> String.split(",") |> Enum.sort() == Enum.sort(friends)
      refute_received {:accounts, _, _, _}

      %{"conversations" => conversations} =
        api(:get, "/api/me/conversations", a) |> json_response(200)

      assert length(conversations) == 3
      assert Enum.all?(conversations, &(&1["other"] == fake_user(&1["other"]["id"])))
      assert Enum.all?(conversations, &(length(&1["members"]) == 2))
      assert_received {:accounts, "GET", "/api/users", _}
      refute_received {:accounts, _, _, _}
    end

    @tag :capture_log
    test "accounts injoignable : ids conservés, display_name/username à null", %{a: a, b: b} do
      conversation = conversation_between(a, b)
      request = api(:post, "/api/friend-requests", uuid(), %{user_id: a}) |> json_response(201)
      Req.Test.stub(MlShared.Client, &Req.Test.transport_error(&1, :econnrefused))
      missing = %{"id" => b, "username" => nil, "display_name" => nil, "avatar" => nil}

      assert %{"friends" => [friend]} = api(:get, "/api/me/friends", a) |> json_response(200)
      assert friend == Map.put(missing, "online_visible", true)

      assert %{"conversations" => [%{"other" => ^missing}]} =
               api(:get, "/api/me/conversations", a) |> json_response(200)

      assert %{"conversation" => %{"other" => ^missing}} =
               api(:get, "/api/conversations/#{conversation.id}", a) |> json_response(200)

      assert %{"incoming" => [%{"id" => id, "from" => %{"display_name" => nil}}]} =
               api(:get, "/api/me/friend-requests", a) |> json_response(200)

      assert id == request["id"]
    end

    @tag :capture_log
    test "id inconnu d'accounts ou réponse en erreur : même repli", %{a: a, b: b, c: c} do
      befriend(a, b)
      befriend(a, c)

      Req.Test.stub(MlShared.Client, &Req.Test.json(&1, %{"users" => [fake_user(b)]}))
      %{"friends" => listed} = api(:get, "/api/me/friends", a) |> json_response(200)
      assert Enum.find(listed, &(&1["id"] == b)) == Map.put(fake_user(b), "online_visible", true)
      assert %{"username" => nil, "display_name" => nil} = Enum.find(listed, &(&1["id"] == c))

      Req.Test.stub(MlShared.Client, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      %{"friends" => listed} = api(:get, "/api/me/friends", a) |> json_response(200)
      assert Enum.all?(listed, &(&1["display_name"] == nil))
    end
  end
end
