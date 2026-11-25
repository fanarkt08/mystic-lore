defmodule MlSocial.SeedsTest do
  # UUID fixes de démonstration partagés : pas d'exécution concurrente avec d'autres tests.
  use MlSocial.DataCase, async: false
  import ExUnit.CaptureIO
  alias MlSocial.{Attachment, Attachments, Chat, Conversation, Friends, Friendship, Message}
  alias MlSocial.{Setting, Settings}

  defp run_seeds, do: capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)

  test "les seeds sont idempotents et référencent les membres de démo" do
    [lea, hugo, ines, sarah, theo, clara] =
      Enum.map(
        ~w(lea_moreau hugo_bernard ines_petit sarah_lefevre theo_garnier clara_dubois),
        &MlShared.Demo.user(&1).id
      )

    schemas = [Friendship, Conversation, Message, Attachment, Setting]
    run_seeds()
    counts = for schema <- schemas, do: Repo.aggregate(schema, :count)
    run_seeds()
    assert counts == for(schema <- schemas, do: Repo.aggregate(schema, :count))

    assert Enum.sort(Friends.friend_ids(lea)) == Enum.sort([hugo, ines])
    assert {[%Friendship{requester_id: ^sarah}], []} = Friends.requests(lea)

    # tri par dernier message : Hugo (il y a 35 min), le groupe (1 h), Inès (vide)
    [with_hugo, group, with_ines] = Chat.list(lea)

    assert %Conversation{kind: "group", name: "Révisions du soir", owner_id: ^lea} =
             group.conversation

    assert Enum.map(group.members, & &1.user_id) == [lea, hugo, ines]
    assert group.unread == 1
    assert Conversation.other(with_hugo.conversation, lea) == hugo
    assert Conversation.other(with_ines.conversation, lea) == ines
    assert with_ines.last_message == nil

    {:ok, %{entries: entries}} = Chat.messages(lea, with_hugo.conversation.id, nil)
    assert length(entries) == 5
    assert Enum.all?(entries, &(DateTime.compare(&1.inserted_at, DateTime.utc_now()) == :lt))
    assert with_hugo.unread == 1
    assert Chat.unread_count(lea) == 2

    # le groupe : message système, 5 messages passés, une vraie image PNG (texte alternatif), non analysée
    {:ok, %{entries: [created | lines]}} = Chat.messages(hugo, group.conversation.id, nil)
    assert %Message{kind: "system", system: %{"event" => "created"}} = created
    assert length(lines) == 5

    assert Enum.all?(
             [created | lines],
             &(DateTime.compare(&1.inserted_at, DateTime.utc_now()) == :lt)
           )

    assert [%Message{sender_id: ^ines, attachment: %Attachment{} = image}] =
             Enum.filter(lines, & &1.attachment)

    assert %Attachment{
             kind: "image",
             content_type: "image/png",
             width: 240,
             height: 160,
             scan: "unscanned"
           } = image

    assert image.alt_text =~ "ciel de nuit"
    assert {:ok, _, <<0x89, "PNG", _::binary>>} = Attachments.file(image)

    # réglages variés
    assert %Setting{show_online: false, read_receipts: false, lobby_invites: "nobody"} =
             Settings.get(ines)

    assert %Setting{show_online: false, group_adds: "nobody"} = Settings.get(sarah)
    assert %Setting{friend_requests: "friends_of_friends"} = Settings.get(theo)
    assert %Setting{friend_requests: "nobody"} = Settings.get(clara)
    assert %Setting{friend_requests: "everyone", read_receipts: true} = Settings.get(lea)
  end
end
