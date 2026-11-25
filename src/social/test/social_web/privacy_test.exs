defmodule MlSocialWeb.PrivacyTest do
  use MlSocialWeb.ConnCase, async: true
  import Ecto.Query, only: [from: 2]
  import MlShared.ImageFixtures, only: [png: 2, pdf: 0]

  alias MlSocial.{
    Attachment,
    Block,
    Conversation,
    Friends,
    Friendship,
    Member,
    Message,
    Repo,
    Report
  }

  defp caller(service, user_id \\ nil) do
    put_req_header(
      build_conn(),
      "authorization",
      "Bearer " <> MlShared.InternalToken.sign(service, user_id)
    )
  end

  setup do
    [me, friend, stranger, blocker, asker] = for _ <- 1..5, do: uuid()
    conversation = conversation_between(me, friend)

    insert_messages(conversation, [
      {me, "Hello from me", 30},
      {friend, "A private reply from my friend", 20},
      {me, "Second message of mine", 10}
    ])

    {:ok, _} = Friends.send_request(asker, me)
    :ok = Friends.block(blocker, me) |> then(fn _ -> :ok end)
    :ok = Friends.block(me, stranger) |> then(fn _ -> :ok end)

    Repo.insert!(%Report{
      reporter_id: me,
      target_type: "message",
      target_id: uuid(),
      reason: "spam",
      details: "Selling potions",
      message_body: "Snapshot of someone else's message",
      message_sender_id: friend
    })

    %{
      me: me,
      friend: friend,
      stranger: stranger,
      blocker: blocker,
      asker: asker,
      conversation: conversation
    }
  end

  test "only the accounts service may call them (403 otherwise)", %{me: me} do
    for conn <- [caller("web", me), caller("multiplayer"), caller("community")] do
      assert %{"error" => "forbidden"} =
               conn |> get("/api/internal/users/#{me}/export") |> json_response(403)

      assert conn |> recycle() |> delete("/api/internal/users/#{me}") |> json_response(403)
    end

    assert Repo.aggregate(Message, :count) == 3
  end

  test "export: friends by public id, own messages only, never the other participant's", %{
    me: me,
    friend: friend,
    stranger: stranger,
    asker: asker,
    conversation: conversation
  } do
    assert %{"data" => data} =
             caller("accounts") |> get("/api/internal/users/#{me}/export") |> json_response(200)

    assert [%{"user_id" => ^friend, "username" => "user_" <> _}] = data["friends"]
    assert [%{"user_id" => ^asker, "direction" => "received"}] = data["friend_requests"]
    assert [%{"user_id" => ^stranger}] = data["blocks"]
    conversation_id = conversation.id
    assert [%{"id" => ^conversation_id, "with_user_id" => ^friend}] = data["conversations"]

    assert Enum.map(data["messages_sent"], & &1["body"]) == [
             "Hello from me",
             "Second message of mine"
           ]

    assert [%{"reason" => "spam", "details" => "Selling potions"}] = data["reports_filed"]

    dump = inspect(data)
    refute dump =~ "A private reply from my friend"
    refute dump =~ "Snapshot of someone else"

    assert caller("accounts") |> get("/api/internal/users/nope/export") |> json_response(404)
  end

  test "DELETE: relations removed both ways, messages kept under the same id, idempotent", %{
    me: me,
    friend: friend,
    blocker: blocker,
    conversation: conversation
  } do
    MlShared.Events.subscribe("user:#{friend}")

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
    assert_receive {:friendship_changed, ^friend}

    assert Repo.all(from f in Friendship, where: f.requester_id == ^me or f.addressee_id == ^me) ==
             []

    assert Repo.all(from b in Block, where: b.blocker_id == ^me or b.blocked_id == ^me) == []
    refute Friends.blocked?(blocker, me)
    assert Repo.all(from m in Member, where: m.user_id == ^me) == []

    # contributions conservées : la conversation reste lisible par l'autre participant
    assert Repo.aggregate(from(m in Message, where: m.sender_id == ^me), :count) == 2

    assert %{"entries" => entries} =
             api("GET", "/api/conversations/#{conversation.id}/messages", friend)
             |> json_response(200)

    assert length(entries) == 3
    assert Repo.aggregate(from(r in Report, where: r.reporter_id == ^me), :count) == 1

    # l'autre participant ne peut plus écrire au membre supprimé
    assert %{"error" => "not_friends"} =
             api("POST", "/api/conversations/#{conversation.id}/messages", friend, %{body: "Hi?"})
             |> json_response(403)

    assert caller("accounts") |> delete("/api/internal/users/#{me}") |> response(204)
  end

  describe "groupes, pièces jointes et réglages" do
    setup %{me: me, friend: friend} do
      other = uuid()
      group = group!(me, [friend, other], "Night owls")
      setting!(me, %{"read_receipts" => false, "lobby_invites" => "nobody"})

      %{"message" => %{"attachment" => %{"id" => image}}} =
        api(:post, "/api/conversations/#{group.id}/messages", me, %{
          body: "Our star chart",
          attachment: attachment(png(12, 12), "chart.png", "A star chart")
        })
        |> json_response(201)

      %{"message" => %{"attachment" => %{"id" => theirs}}} =
        api(:post, "/api/conversations/#{group.id}/messages", friend, %{
          attachment: attachment(pdf(), "their-notes.pdf")
        })
        |> json_response(201)

      %{group: group, other: other, image: image, theirs: theirs}
    end

    test "export : réglages, groupes avec rôle, SES pièces jointes avec leur contenu, jamais celles des autres",
         ctx do
      assert %{"data" => data} =
               caller("accounts")
               |> get("/api/internal/users/#{ctx.me}/export")
               |> json_response(200)

      assert %{"read_receipts" => false, "lobby_invites" => "nobody"} = data["settings"]
      group_id = ctx.group.id

      assert %{
               "kind" => "group",
               "name" => "Night owls",
               "role" => "owner",
               "with_user_id" => nil
             } =
               Enum.find(data["conversations"], &(&1["id"] == group_id))

      assert [%{"id" => image, "filename" => "chart.png", "alt_text" => "A star chart"} = file] =
               data["attachments_sent"]

      assert image == ctx.image
      assert {:ok, <<0x89, "PNG", _::binary>>} = Base.decode64(file["data_base64"])
      assert Enum.any?(data["messages_sent"], &(&1["attachment_id"] == image))
      refute inspect(data) =~ "their-notes"
    end

    test "suppression : fichiers effacés, groupe quitté (propriété transférée), autres pièces jointes intactes",
         ctx do
      %Attachment{storage_key: key} = Repo.get!(Attachment, ctx.image)
      file = Path.join([Application.fetch_env!(:social, :storage_dir), "attachments", key])
      assert File.exists?(file)

      assert caller("accounts") |> delete("/api/internal/users/#{ctx.me}") |> response(204)

      refute File.exists?(file)

      assert %Attachment{erased_at: %DateTime{}, storage_key: nil, filename: nil, alt_text: nil} =
               Repo.get!(Attachment, ctx.image)

      assert %Conversation{owner_id: owner} = Repo.get!(Conversation, ctx.group.id)
      assert owner == ctx.friend

      # le fil garde la place du message ; la pièce jointe n'est plus servie
      assert %{"entries" => entries} =
               api(:get, "/api/conversations/#{ctx.group.id}/messages", ctx.friend)
               |> json_response(200)

      assert %{"attachment" => %{"available" => false}} =
               Enum.find(entries, &(&1["body"] == "Our star chart"))

      assert api(:get, "/api/attachments/#{ctx.image}", ctx.friend) |> json_response(404)
      assert api(:get, "/api/attachments/#{ctx.theirs}", ctx.other) |> response(200)

      assert caller("accounts") |> delete("/api/internal/users/#{ctx.me}") |> response(204)
    end
  end
end
