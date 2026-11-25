defmodule MlSocialWeb.NotifyTest do
  @moduledoc """
  Producteur `messages` / `friends` (faux centre de notifications de `MlSocialWeb.ConnCase`) : destinataires,
  sourdine, blocages, lecture, demandes d'ami, groupes, et jamais le texte d'un message.
  """
  use MlSocialWeb.ConnCase, async: true

  # notifications créées depuis le dernier relevé (boîte aux lettres vidée)
  defp created(acc \\ []) do
    receive do
      {:center, "/api/internal/notifications", body} -> created([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp center_calls(path, acc \\ []) do
    receive do
      {:center, ^path, body} -> center_calls(path, [body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # oublie les appels déjà faits (préparation du test)
  defp drain do
    receive do
      {:center, _path, _body} -> drain()
    after
      0 -> :ok
    end
  end

  defp say(conversation_id, sender, body) do
    api(:post, "/api/conversations/#{conversation_id}/messages", sender, %{"body" => body})
    |> json_response(201)
  end

  test "a direct message notifies the other member only, without its text, aggregated by conversation" do
    [a, b] = [uuid(), uuid()]
    conversation = conversation_between(a, b)
    _ = created()

    %{"message" => %{"id" => message_id}} = say(conversation.id, a, "Meet me at the grove at 9")

    assert [n] = created()

    assert %{
             "user_id" => ^b,
             "category" => "messages",
             "kind" => "message_received",
             "actor_id" => ^a,
             "params" => %{"conversation_id" => cid, "conversation_kind" => "direct"},
             "dedupe_key" => key,
             "event_id" => event,
             "occurred_at" => _
           } = n

    assert cid == conversation.id and key == "conversation:#{cid}" and
             event == "message:#{message_id}"

    refute inspect(n) =~ "grove"
  end

  test "group: every current member but the sender; nothing for a muted member or a blocked pair" do
    [owner, b, c, d] = [uuid(), uuid(), uuid(), uuid()]
    group = group!(owner, [b, c, d], "Night owls")
    _ = created()

    api(:put, "/api/conversations/#{group.id}/mute", c, %{"duration" => "8h"})
    |> json_response(200)

    api(:post, "/api/blocks", d, %{"user_id" => owner}) |> response(204)
    _ = created()

    say(group.id, owner, "Hello owls")
    assert [%{"user_id" => ^b, "params" => params}] = created()

    assert params == %{
             "conversation_id" => group.id,
             "conversation_kind" => "group",
             "group_name" => "Night owls"
           }

    # a system message (rename) is not a message notification
    api(:patch, "/api/conversations/#{group.id}", owner, %{"name" => "Early birds"})
    |> json_response(200)

    assert created() == []
  end

  test "reading the conversation marks its notification read (key and moment of the read)" do
    [a, b] = [uuid(), uuid()]
    conversation = conversation_between(a, b)
    say(conversation.id, a, "Hi")
    drain()
    api(:post, "/api/conversations/#{conversation.id}/read", b) |> response(204)

    assert [%{"user_id" => ^b, "dedupe_key" => key, "read_at" => read_at}] =
             center_calls("/api/internal/notifications/read")

    assert key == "conversation:#{conversation.id}"
    assert {:ok, _, _} = DateTime.from_iso8601(read_at)
  end

  test "friend request received, accepted (request marked read), declined; a block clears the pair" do
    [a, b, c] = [uuid(), uuid(), uuid()]

    %{"id" => request} =
      api(:post, "/api/friend-requests", a, %{"user_id" => b}) |> json_response(201)

    assert [
             %{
               "user_id" => ^b,
               "kind" => "friend_request_received",
               "actor_id" => ^a,
               "params" => %{"request_id" => ^request},
               "dedupe_key" => key
             }
           ] = created()

    assert key == "friend_request:#{request}"

    api(:post, "/api/friend-requests/#{request}/accept", b) |> json_response(200)

    assert [%{"user_id" => ^a, "kind" => "friend_request_accepted", "actor_id" => ^b}] = created()

    assert [%{"user_id" => ^b, "dedupe_key" => ^key}] =
             center_calls("/api/internal/notifications/read")

    # crossed requests: accepting by sending one back notifies the first requester
    %{"id" => r2} = api(:post, "/api/friend-requests", c, %{"user_id" => a}) |> json_response(201)
    _ = created()
    api(:post, "/api/friend-requests", a, %{"user_id" => c}) |> json_response(200)
    assert [%{"user_id" => ^c, "kind" => "friend_request_accepted", "actor_id" => ^a}] = created()
    assert [%{"user_id" => ^a}] = center_calls("/api/internal/notifications/read")

    # declined
    d = uuid()
    %{"id" => r3} = api(:post, "/api/friend-requests", d, %{"user_id" => b}) |> json_response(201)
    _ = created()
    api(:post, "/api/friend-requests/#{r3}/decline", b) |> response(204)

    assert [%{"user_id" => ^b, "dedupe_key" => k3}] =
             center_calls("/api/internal/notifications/read")

    assert k3 == "friend_request:#{r3}"
    assert r2 != r3

    api(:post, "/api/blocks", b, %{"user_id" => a}) |> response(204)
    assert [%{"a" => ^b, "b" => ^a}] = center_calls("/api/internal/notifications/clear-between")
  end

  test "group creation and addition notify the added friends; a removed member's group notifications are read" do
    [owner, b, c, e] = [uuid(), uuid(), uuid(), uuid()]
    group = group!(owner, [b, c])

    added = created() |> Enum.filter(&(&1["kind"] == "group_added"))
    assert added |> Enum.map(& &1["user_id"]) |> Enum.sort() == Enum.sort([b, c])

    assert Enum.all?(
             added,
             &(&1["params"]["conversation_id"] == group.id and &1["actor_id"] == owner)
           )

    befriend(owner, e)
    _ = created()

    api(:post, "/api/conversations/#{group.id}/members", owner, %{"user_id" => e})
    |> json_response(200)

    assert [%{"user_id" => ^e, "kind" => "group_added", "dedupe_key" => key}] =
             Enum.filter(created(), &(&1["kind"] == "group_added"))

    assert key == "group:#{group.id}:added"

    drain()
    api(:delete, "/api/conversations/#{group.id}/members/#{e}", owner) |> json_response(200)

    assert center_calls("/api/internal/notifications/read")
           |> Enum.map(&{&1["user_id"], &1["dedupe_key"]}) ==
             [{e, "conversation:#{group.id}"}, {e, "group:#{group.id}:added"}]
  end

  test "the center unreachable never fails the original action" do
    [a, b] = [uuid(), uuid()]
    conversation = conversation_between(a, b)

    Req.Test.stub(MlShared.Client, fn
      %Plug.Conn{request_path: "/api/internal/notifications" <> _} = conn ->
        Req.Test.transport_error(conn, :econnrefused)

      conn ->
        fake_accounts(conn)
    end)

    assert %{"message" => %{"body" => "Still delivered"}} =
             say(conversation.id, a, "Still delivered")

    api(:post, "/api/conversations/#{conversation.id}/read", b) |> response(204)

    assert %{"id" => _} =
             api(:post, "/api/friend-requests", a, %{"user_id" => uuid()}) |> json_response(201)
  end
end
