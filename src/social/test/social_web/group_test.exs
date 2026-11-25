defmodule MlSocialWeb.GroupTest do
  use MlSocialWeb.ConnCase, async: true
  import Ecto.Query
  import MlShared.ImageFixtures
  alias MlShared.Events
  alias MlSocial.{Conversation, Member, Message, Repo}

  setup do
    {:ok, owner: uuid(), b: uuid(), c: uuid(), d: uuid()}
  end

  defp create(me, body), do: api(:post, "/api/groups", me, body)
  defp path(group, suffix \\ "")
  defp path(%{"id" => id}, suffix), do: "/api/conversations/#{id}#{suffix}"
  defp path(%{id: id}, suffix), do: "/api/conversations/#{id}#{suffix}"
  defp say(group, user, body), do: api(:post, path(group, "/messages"), user, %{body: body})
  defp history(group, user), do: api(:get, path(group, "/messages"), user)

  defp events(fun) do
    fun.()
    collect([])
  end

  defp collect(acc) do
    receive do
      {tag, _} = event when tag in [:new_message, :conversation_changed] -> collect([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "création" do
    test "nom de 1 à 60 caractères, 3 à 20 membres créateur compris, amis seulement", %{
      owner: owner,
      b: b,
      c: c
    } do
      Enum.each([b, c], &befriend(owner, &1))

      for {name, message} <- [
            {"", "can't be blank"},
            {"   ", "can't be blank"},
            {String.duplicate("é", 61), "should be at most 60 character(s)"},
            {"Grove\u202Eeman", "must not contain control characters"},
            {nil, "can't be blank"}
          ] do
        assert %{"errors" => %{"name" => [^message]}} =
                 create(owner, %{name: name, member_ids: [b, c]}) |> json_response(422)
      end

      for ids <- [[], [b], [b, owner], [b, b], "nope", [b, "x"]] do
        assert %{"errors" => %{"member_ids" => [_]}} =
                 create(owner, %{name: "Circle", member_ids: ids}) |> json_response(422)
      end

      too_many = for _ <- 1..20, do: uuid()

      assert %{"errors" => %{"member_ids" => ["must list 2 to 19 friends"]}} =
               create(owner, %{name: "Crowd", member_ids: too_many}) |> json_response(422)

      assert %{"conversation" => group} =
               create(owner, %{name: "  Moonlit circle  ", member_ids: [b, c]})
               |> json_response(201)

      assert %{
               "kind" => "group",
               "name" => "Moonlit circle",
               "owner_id" => ^owner,
               "other" => nil
             } =
               group

      assert Enum.map(group["members"], &{&1["user"]["id"], &1["role"]}) ==
               [{owner, "owner"}, {b, "member"}, {c, "member"}]

      assert %{"entries" => [created]} = history(group, c) |> json_response(200)

      assert %{"kind" => "system", "body" => nil, "sender_id" => ^owner} = created

      assert created["system"] == %{
               "event" => "created",
               "actor_id" => owner,
               "name" => "Moonlit circle"
             }
    end

    test "20 membres au plus ; chaque membre doit être ami, sans blocage, et accepter les ajouts",
         %{
           owner: owner,
           b: b,
           c: c,
           d: d
         } do
      nineteen = for _ <- 1..19, do: uuid()
      Enum.each(nineteen, &befriend(owner, &1))

      assert %{"conversation" => big} =
               create(owner, %{name: "Big", member_ids: nineteen}) |> json_response(201)

      assert length(big["members"]) == 20

      befriend(owner, b)
      # c n'est pas ami : refus nommé, rien n'est créé
      assert %{"error" => "not_friends", "user_id" => ^c} =
               create(owner, %{name: "Trio", member_ids: [b, c]}) |> json_response(403)

      api(:post, "/api/blocks", d, %{user_id: owner}) |> response(204)

      assert %{"error" => "blocked", "user_id" => ^d} =
               create(owner, %{name: "Trio", member_ids: [b, d]}) |> json_response(403)

      befriend(owner, c)
      setting!(c, %{"group_adds" => "nobody"})

      assert %{"error" => "group_adds_closed", "user_id" => ^c} =
               create(owner, %{name: "Trio", member_ids: [b, c]}) |> json_response(403)

      assert Repo.aggregate(from(x in Conversation, where: x.kind == "group"), :count) == 1
    end

    test "chaque membre reçoit le message système et conversation_changed sur son topic", ctx do
      Enum.each([ctx.b, ctx.c], &befriend(ctx.owner, &1))
      for user <- [ctx.owner, ctx.b, ctx.c, ctx.d], do: Events.subscribe(Events.user(user))

      received =
        events(fn ->
          create(ctx.owner, %{name: "Live", member_ids: [ctx.b, ctx.c]}) |> json_response(201)
        end)

      # 3 membres → 3 copies de chaque événement, rien pour d
      assert Enum.count(received, &match?({:new_message, %{"kind" => "system"}}, &1)) == 3
      assert Enum.count(received, &match?({:conversation_changed, _}, &1)) == 3
    end
  end

  describe "rôles" do
    setup ctx, do: %{group: group!(ctx.owner, [ctx.b, ctx.c])}

    test "le propriétaire renomme ; un membre ne peut pas ; une conversation directe n'est pas un groupe",
         ctx do
      assert %{"error" => "not_owner"} =
               api(:patch, path(ctx.group), ctx.b, %{name: "Mine"}) |> json_response(403)

      assert %{"conversation" => %{"name" => "Starlit circle"}} =
               api(:patch, path(ctx.group), ctx.owner, %{name: "Starlit circle"})
               |> json_response(200)

      # même nom : rien de plus dans le fil
      api(:patch, path(ctx.group), ctx.owner, %{name: "Starlit circle"}) |> json_response(200)

      assert %{"entries" => [_created, renamed]} = history(ctx.group, ctx.c) |> json_response(200)

      assert renamed["system"] == %{
               "event" => "renamed",
               "actor_id" => ctx.owner,
               "name" => "Starlit circle"
             }

      direct = conversation_between(ctx.owner, ctx.d)

      assert api(:patch, path(direct), ctx.owner, %{name: "Nope"}) |> json_response(404)
      assert api(:post, path(direct, "/leave"), ctx.owner) |> json_response(404)
    end

    test "ajout par le propriétaire : ami requis, déjà membre 409, plein 409 ; l'ajouté lit la suite seulement",
         ctx do
      say(ctx.group, ctx.b, "before d") |> json_response(201)

      assert %{"error" => "not_owner"} =
               api(:post, path(ctx.group, "/members"), ctx.b, %{user_id: ctx.d})
               |> json_response(403)

      assert %{"error" => "not_friends", "user_id" => _} =
               api(:post, path(ctx.group, "/members"), ctx.owner, %{user_id: ctx.d})
               |> json_response(403)

      befriend(ctx.owner, ctx.d)
      Events.subscribe(Events.user(ctx.d))

      assert %{"conversation" => %{"members" => members}} =
               api(:post, path(ctx.group, "/members"), ctx.owner, %{user_id: ctx.d})
               |> json_response(200)

      assert length(members) == 4
      assert_receive {:conversation_changed, _}

      assert_receive {:new_message,
                      %{"system" => %{"event" => "member_added", "target_id" => target}}}

      assert target == ctx.d

      assert %{"error" => "already_member"} =
               api(:post, path(ctx.group, "/members"), ctx.owner, %{user_id: ctx.d})
               |> json_response(409)

      # son historique commence à son arrivée : l'annonce de son ajout, rien de ce qui précède
      assert %{"entries" => entries} = history(ctx.group, ctx.d) |> json_response(200)
      assert [%{"system" => %{"event" => "member_added"}}] = entries

      for _ <- 1..16 do
        friend = uuid()
        befriend(ctx.owner, friend)

        api(:post, path(ctx.group, "/members"), ctx.owner, %{user_id: friend})
        |> json_response(200)
      end

      late = uuid()
      befriend(ctx.owner, late)

      assert %{"error" => "group_full"} =
               api(:post, path(ctx.group, "/members"), ctx.owner, %{user_id: late})
               |> json_response(409)
    end

    test "historique d'un membre ajouté : depuis son arrivée (fil, liste, non-lus, pièce jointe, signalement)",
         ctx do
      %{"message" => %{"id" => before_id, "attachment" => %{"id" => before_file}}} =
        api(:post, path(ctx.group, "/messages"), ctx.b, %{
          body: "said before d",
          attachment: attachment(png(), "sky.png")
        })
        |> json_response(201)

      befriend(ctx.owner, ctx.d)
      add = fn -> api(:post, path(ctx.group, "/members"), ctx.owner, %{user_id: ctx.d}) end
      add.() |> json_response(200)

      # liste et compteurs : le dernier message visible est l'annonce de son ajout, aucun non-lu d'avant
      assert %{"conversations" => [listed]} =
               api(:get, "/api/me/conversations", ctx.d) |> json_response(200)

      assert %{"system" => %{"event" => "member_added"}} = listed["last_message"]
      assert listed["unread"] == 0
      assert %{"messages" => 0} = api(:get, "/api/me/unread", ctx.d) |> json_response(200)

      # pièce jointe et message d'avant son arrivée : comme s'ils n'existaient pas pour lui
      assert %{"error" => "not_found"} =
               api(:get, "/api/attachments/#{before_file}", ctx.d) |> json_response(404)

      assert %{"errors" => %{"target_id" => ["is invalid"]}} =
               api(:post, "/api/reports", ctx.d, %{
                 target_type: "message",
                 target_id: before_id,
                 reason: "spam"
               })
               |> json_response(422)

      # les membres déjà là gardent tout
      assert %{"entries" => kept} = history(ctx.group, ctx.c) |> json_response(200)
      assert Enum.any?(kept, &(&1["body"] == "said before d"))
      assert api(:get, "/api/attachments/#{before_file}", ctx.c) |> response(200)

      # la suite : lue et comptée
      say(ctx.group, ctx.b, "after d") |> json_response(201)
      assert %{"entries" => entries} = history(ctx.group, ctx.d) |> json_response(200)

      assert ["member_added", "after d"] =
               Enum.map(entries, &(&1["body"] || &1["system"]["event"]))

      assert %{"messages" => 1} = api(:get, "/api/me/unread", ctx.d) |> json_response(200)

      # parti puis rajouté : l'historique repart de son retour
      assert api(:post, path(ctx.group, "/leave"), ctx.d) |> response(204)
      add.() |> json_response(200)
      assert %{"entries" => entries} = history(ctx.group, ctx.d) |> json_response(200)
      assert [%{"system" => %{"event" => "member_added"}}] = entries
    end

    test "membre retiré : plus rien ne lui est livré, et toute route lui répond 404", ctx do
      say(ctx.group, ctx.c, "hello all") |> json_response(201)
      Events.subscribe(Events.user(ctx.c))

      assert %{"error" => "not_owner"} =
               api(:delete, path(ctx.group, "/members/#{ctx.b}"), ctx.c) |> json_response(403)

      assert %{"error" => "self"} =
               api(:delete, path(ctx.group, "/members/#{ctx.owner}"), ctx.owner)
               |> json_response(422)

      assert %{"conversation" => %{"members" => members}} =
               api(:delete, path(ctx.group, "/members/#{ctx.c}"), ctx.owner) |> json_response(200)

      refute Enum.any?(members, &(&1["user"]["id"] == ctx.c))
      # sa page ouverte apprend son retrait (sans contenu), puis ne reçoit plus aucun message
      assert_receive {:conversation_changed, _}
      refute_received {:new_message, _}

      say(ctx.group, ctx.owner, "secret after removal") |> json_response(201)
      refute_receive {:new_message, _}, 100

      for {method, suffix, body} <- [
            {:get, "", nil},
            {:get, "/messages", nil},
            {:post, "/messages", %{body: "still here?"}},
            {:post, "/read", nil},
            {:post, "/leave", nil},
            {:put, "/mute", %{duration: "1h"}}
          ] do
        assert %{"error" => "not_found"} =
                 api(method, path(ctx.group, suffix), ctx.c, body) |> json_response(404)
      end

      assert %{"entries" => entries} = history(ctx.group, ctx.b) |> json_response(200)

      assert %{"system" => %{"event" => "member_removed", "target_id" => removed}} =
               List.last(Enum.filter(entries, &(&1["kind"] == "system")))

      assert removed == ctx.c
      assert api(:delete, path(ctx.group, "/members/#{ctx.c}"), ctx.owner) |> json_response(404)
    end

    test "le propriétaire part : propriété au plus ancien ; le dernier qui part supprime le groupe",
         ctx do
      assert api(:post, path(ctx.group, "/leave"), ctx.owner) |> response(204)

      assert %Conversation{owner_id: owner} = Repo.get!(Conversation, ctx.group.id)
      assert owner == ctx.b

      assert %{"entries" => entries} = history(ctx.group, ctx.c) |> json_response(200)

      assert %{"system" => %{"event" => "member_left", "actor_id" => left, "target_id" => ^owner}} =
               List.last(entries)

      assert left == ctx.owner

      assert api(:post, path(ctx.group, "/leave"), ctx.c) |> response(204)
      assert %Conversation{owner_id: ^owner} = Repo.get!(Conversation, ctx.group.id)

      assert api(:post, path(ctx.group, "/leave"), ctx.b) |> response(204)
      refute Repo.get(Conversation, ctx.group.id)

      assert Repo.aggregate(from(m in Message, where: m.conversation_id == ^ctx.group.id), :count) ==
               0

      assert Repo.aggregate(from(m in Member, where: m.conversation_id == ^ctx.group.id), :count) ==
               0
    end
  end

  describe "envoi dans un groupe" do
    test "tout membre écrit (sans amitié entre membres), chacun reçoit en direct ; liste et non-lus",
         ctx do
      group = group!(ctx.owner, [ctx.b, ctx.c])
      for user <- [ctx.b, ctx.c], do: Events.subscribe(Events.user(user))

      # b et c ne sont pas amis : l'envoi dans le groupe reste possible
      assert %{"message" => message} = say(group, ctx.b, "Hi everyone") |> json_response(201)
      assert_receive {:new_message, ^message}
      assert_receive {:new_message, ^message}
      assert_receive {:unread_changed, c}
      assert c == ctx.c

      assert %{"conversations" => [%{"kind" => "group", "unread" => 1, "last_message" => last}]} =
               api(:get, "/api/me/conversations", ctx.c) |> json_response(200)

      assert last["body"] == "Hi everyone"
      # les messages système ne comptent pas dans les non-lus
      assert %{"messages" => 1} = api(:get, "/api/me/unread", ctx.c) |> json_response(200)
      assert %{"messages" => 0} = api(:get, "/api/me/unread", ctx.b) |> json_response(200)
    end
  end
end
