defmodule MlSocialWeb.GroupBlocksTest do
  @moduledoc "Blocage dans un groupe : messages filtrés côté serveur pour le lecteur, dans les deux sens."
  use MlSocialWeb.ConnCase, async: true
  import MlShared.ImageFixtures, only: [png: 2]
  alias MlShared.Events

  setup do
    [owner, b, c] = for _ <- 1..3, do: uuid()
    group = group!(owner, [b, c])
    # c bloque b (b et c ne sont pas amis : le blocage est possible entre membres d'un groupe)
    api(:post, "/api/blocks", c, %{user_id: b}) |> response(204)
    %{owner: owner, b: b, c: c, group: group}
  end

  defp say(ctx, user, body),
    do: api(:post, "/api/conversations/#{ctx.group.id}/messages", user, body)

  defp entries(ctx, user) do
    api(:get, "/api/conversations/#{ctx.group.id}/messages", user)
    |> json_response(200)
  end

  test "les messages de b sont masqués pour c, ceux de c pour b ; le propriétaire voit tout",
       ctx do
    say(ctx, ctx.b, %{body: "from b"}) |> json_response(201)
    say(ctx, ctx.c, %{body: "from c"}) |> json_response(201)

    for {reader, visible, hidden} <- [{ctx.c, "from c", ctx.b}, {ctx.b, "from b", ctx.c}] do
      page = entries(ctx, reader)
      texts = Enum.filter(page["entries"], &(&1["kind"] == "text"))
      assert Enum.map(texts, & &1["body"]) |> Enum.sort() == Enum.sort([visible, nil])

      masked = Enum.find(texts, & &1["hidden"])

      assert %{"sender_id" => nil, "body" => nil, "attachment" => nil, "removed" => false} =
               masked

      # ni l'identité de l'expéditeur masqué, ni son texte, nulle part dans la réponse
      refute Enum.any?(page["users"], &(&1["id"] == hidden))
      refute Jason.encode!(page) =~ if(reader == ctx.c, do: "from b", else: "from c")
    end

    owner_page = entries(ctx, ctx.owner)

    assert owner_page["entries"] |> Enum.filter(&(&1["kind"] == "text")) |> Enum.map(& &1["body"]) ==
             ["from b", "from c"]
  end

  test "livraison en direct masquée, pièce jointe inaccessible, non-lus et aperçu sans le message",
       ctx do
    for user <- [ctx.owner, ctx.c], do: Events.subscribe(Events.user(user))

    %{"message" => %{"id" => id, "attachment" => %{"id" => attachment_id}}} =
      say(ctx, ctx.b, %{body: "look", attachment: attachment(png(8, 8), "secret.png")})
      |> json_response(201)

    messages =
      for _ <- 1..2 do
        assert_receive {:new_message, %{"id" => ^id} = message}
        message
      end

    assert Enum.count(messages, & &1["hidden"]) == 1
    assert Enum.count(messages, &(&1["body"] == "look")) == 1

    assert api(:get, "/api/attachments/#{attachment_id}", ctx.c) |> response(404)
    assert api(:get, "/api/attachments/#{attachment_id}", ctx.owner) |> response(200)

    assert %{"messages" => 0} = api(:get, "/api/me/unread", ctx.c) |> json_response(200)
    assert %{"messages" => 1} = api(:get, "/api/me/unread", ctx.owner) |> json_response(200)

    assert %{"conversations" => [%{"unread" => 0, "last_message" => last}]} =
             api(:get, "/api/me/conversations", ctx.c) |> json_response(200)

    assert %{"hidden" => true, "body" => nil, "sender_id" => nil} = last
  end

  test "une conversation directe reste lisible après un blocage (l'envoi y est refusé)", ctx do
    other = uuid()
    direct = conversation_between(ctx.owner, other)

    api(:post, "/api/conversations/#{direct.id}/messages", other, %{body: "before"})
    |> json_response(201)

    api(:post, "/api/blocks", ctx.owner, %{user_id: other}) |> response(204)

    assert %{"entries" => [%{"body" => "before", "hidden" => false}]} =
             api(:get, "/api/conversations/#{direct.id}/messages", ctx.owner)
             |> json_response(200)
  end
end
