defmodule MlCommunityWeb.ReplyControllerTest do
  use MlCommunityWeb.ConnCase, async: true
  import Ecto.Query
  alias MlCommunity.{Discussion, Follow, Reply, Repo}

  setup do
    a = uuid()
    {:ok, a: a, b: uuid(), discussion: discussion!(a)}
  end

  defp post_reply(user, discussion, body \\ "Counting starts at zero."),
    do: api(:post, "/api/discussions/#{discussion.slug}/replies", user, %{"body" => body})

  test "reply: 201, discussion activity bumped, replier follows the discussion", %{
    b: b,
    discussion: d
  } do
    %{"reply" => reply} = post_reply(b, d, "  Counting starts at zero.  ") |> json_response(201)

    assert %{
             "body" => "Counting starts at zero.",
             "author" => %{"id" => ^b},
             "status" => "visible",
             "can_edit" => true,
             "voted" => false,
             "solution" => false,
             "helpful_count" => 0
           } = reply

    assert DateTime.compare(Repo.get!(Discussion, d.id).last_activity_at, d.last_activity_at) ==
             :gt

    assert Repo.get_by(Follow, user_id: b, discussion_id: d.id)

    assert %{"errors" => %{"body" => ["can't be blank"]}} =
             post_reply(b, d, "   ") |> json_response(422)

    assert post_reply(b, %{slug: "unknown"}) |> json_response(404)
  end

  test "locked discussion: members can't reply, the staff can", %{b: b, discussion: d} do
    Repo.update_all(where(Discussion, id: ^d.id), set: [locked: true])
    assert %{"error" => "locked"} = post_reply(b, d) |> json_response(403)

    staff = uuid()
    stub_services(staff: [staff])
    assert post_reply(staff, d) |> json_response(201)
  end

  test "IDOR and edit window on replies", %{a: a, b: b, discussion: d} do
    reply = reply!(b, d)

    assert %{"error" => "forbidden"} =
             api(:patch, "/api/replies/#{reply.id}", a, %{"body" => "Hijacked!"})
             |> json_response(403)

    assert %{"error" => "forbidden"} =
             api(:delete, "/api/replies/#{reply.id}", a) |> json_response(403)

    assert %{"reply" => %{"body" => "Better wording.", "edited_at" => edited}} =
             api(:patch, "/api/replies/#{reply.id}", b, %{"body" => "Better wording."})
             |> json_response(200)

    assert edited

    age!(reply, 45)

    assert %{"error" => "edit_window_expired"} =
             api(:patch, "/api/replies/#{reply.id}", b, %{"body" => "Too late now."})
             |> json_response(403)

    assert Repo.get!(Reply, reply.id).body == "Better wording."
    assert api(:patch, "/api/replies/not-a-uuid", b, %{"body" => "x y"}) |> json_response(404)
  end

  test "deleting a reply is logical and removes it from the solution", %{
    a: a,
    b: b,
    discussion: d
  } do
    reply = reply!(b, d)
    {:ok, _} = MlCommunity.Posts.set_solution(viewer(a), d.slug, reply.id)

    assert response(api(:delete, "/api/replies/#{reply.id}", b), 204)
    assert Repo.get!(Reply, reply.id).status == "deleted"
    assert Repo.get!(Discussion, d.id).solution_reply_id == nil

    %{"replies" => %{"entries" => []}, "discussion" => %{"reply_count" => 0}} =
      api(:get, "/api/discussions/#{d.slug}", a) |> json_response(200)

    assert api(:delete, "/api/replies/#{reply.id}", b) |> json_response(404)
  end

  test "helpful votes on replies: idempotent, not on one's own", %{a: a, b: b, discussion: d} do
    reply = reply!(b, d)

    assert %{"voted" => true, "helpful_count" => 1} =
             api(:put, "/api/replies/#{reply.id}/vote", a) |> json_response(200)

    assert %{"voted" => true, "helpful_count" => 1} =
             api(:put, "/api/replies/#{reply.id}/vote", a) |> json_response(200)

    assert %{"replies" => %{"entries" => [%{"voted" => true, "helpful_count" => 1}]}} =
             api(:get, "/api/discussions/#{d.slug}", a) |> json_response(200)

    assert %{"error" => "own_content"} =
             api(:put, "/api/replies/#{reply.id}/vote", b) |> json_response(403)

    assert %{"voted" => false, "helpful_count" => 0} =
             api(:delete, "/api/replies/#{reply.id}/vote", a) |> json_response(200)
  end

  describe "rate limit" do
    test "10 publications (discussions + replies) per 10 minutes and per member", %{
      a: a,
      discussion: d
    } do
      # `a` a déjà publié sa discussion : 9 réponses de plus atteignent la limite.
      for i <- 1..9, do: assert(post_reply(a, d, "Reply number #{i}") |> json_response(201))

      assert %{"error" => "rate_limited"} = post_reply(a, d) |> json_response(429)

      assert %{"error" => "rate_limited"} =
               api(:post, "/api/discussions", a, %{
                 "category" => "off-topic",
                 "title" => "One more discussion",
                 "body" => "This one is over the limit."
               })
               |> json_response(429)

      # les publications sorties de la fenêtre ne comptent plus ; les autres membres ne sont pas concernés
      assert post_reply(uuid(), d) |> json_response(201)

      Repo.update_all(where(Reply, author_id: ^a),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -11 * 60)]
      )

      assert post_reply(a, d) |> json_response(201)
    end
  end

  describe "follow notifications" do
    test "followers get {:community_reply, slug, title}, except the author and blocked members",
         %{
           a: a,
           b: b,
           discussion: d
         } do
      {follower, blocked_by_replier, blocked_with_author} = {uuid(), uuid(), uuid()}

      for user <- [follower, blocked_by_replier, blocked_with_author] do
        :ok = MlCommunity.Posts.follow(viewer(user), d.slug)
      end

      stub_services(blocks: [{b, blocked_by_replier}, {a, blocked_with_author}])
      Enum.each([a, b, follower, blocked_by_replier, blocked_with_author], &listen/1)

      assert post_reply(b, d) |> json_response(201)

      slug = d.slug
      title = d.title
      assert_receive {:event, ^a, {:community_reply, ^slug, ^title}}
      assert_receive {:event, ^follower, {:community_reply, ^slug, ^title}}
      refute_receive {:event, ^b, {:community_reply, _, _}}, 100
      refute_received {:event, ^blocked_by_replier, {:community_reply, _, _}}
      refute_received {:event, ^blocked_with_author, {:community_reply, _, _}}
    end

    test "the notification center gets one community_reply per follower, never the reply body", %{
      a: a,
      b: b,
      discussion: d
    } do
      {follower, blocked_with_author} = {uuid(), uuid()}

      for user <- [follower, blocked_with_author],
          do: :ok = MlCommunity.Posts.follow(viewer(user), d.slug)

      stub_services(blocks: [{a, blocked_with_author}])

      assert %{"reply" => %{"id" => reply_id}} = post_reply(b, d) |> json_response(201)

      notified =
        for _ <- 1..2 do
          assert_receive {:center, body}
          body
        end

      refute_received {:center, _}
      assert notified |> Enum.map(& &1["user_id"]) |> Enum.sort() == Enum.sort([a, follower])

      for n <- notified do
        assert %{
                 "category" => "community",
                 "kind" => "community_reply",
                 "actor_id" => ^b,
                 "params" => %{"slug" => slug, "title" => title, "discussion_id" => id},
                 "dedupe_key" => key,
                 "event_id" => event
               } = n

        assert {slug, title, id} == {d.slug, d.title, d.id}
        assert key == "discussion:#{d.id}" and event == "reply:#{reply_id}"
        refute inspect(n) =~ "Counting starts"
      end
    end

    @tag :capture_log
    test "the center unreachable: the reply is still published", %{b: b, discussion: d} do
      stub_services(down: ["notifications"])
      assert %{"reply" => %{"id" => _}} = post_reply(b, d) |> json_response(201)
    end

    @tag :capture_log
    test "if social can't answer for the discussion author, nobody is notified (prudent)", %{
      a: a,
      b: b,
      discussion: d
    } do
      # les blocages de `b` sont en cache ; ceux de `a` ne peuvent plus être lus
      {:ok, _} = MlCommunity.Social.blocked_ids(b)
      :ets.delete(MlCommunity.Cache, {:blocks, a})
      stub_services(down: ["social"])
      listen(a)

      assert post_reply(b, d) |> json_response(201)
      refute_receive {:event, ^a, {:community_reply, _, _}}, 100
    end
  end
end
