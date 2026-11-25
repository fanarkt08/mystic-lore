defmodule MlCommunityWeb.VisibilityTest do
  @moduledoc "Contenus masqués / retirés et blocages : filtrés côté serveur, dans les requêtes."
  use MlCommunityWeb.ConnCase, async: true
  import Ecto.Query
  alias MlCommunity.{Discussion, Reply, Repo}

  setup do
    {author, other, staff} = {uuid(), uuid(), uuid()}
    stub_services(staff: [staff])
    {:ok, author: author, other: other, staff: staff}
  end

  defp set_status(%schema{id: id}, status, reason \\ "Spoilers for the final chapter") do
    Repo.update_all(from(x in schema, where: x.id == ^id),
      set: [status: status, moderation_reason: reason]
    )
  end

  defp slugs(user, query \\ "") do
    api(:get, "/api/discussions?" <> query, user)
    |> json_response(200)
    |> Map.fetch!("entries")
    |> Enum.map(& &1["slug"])
  end

  describe "moderated content" do
    test "hidden or removed discussions: only their author and the staff see them (with the reason)",
         %{author: author, other: other, staff: staff} do
      for status <- ~w(hidden removed) do
        d = discussion!(author, %{"title" => "Moderated #{status} topic"})
        set_status(d, status)

        for user <- [other, nil] do
          assert api(:get, "/api/discussions/#{d.slug}", user) |> json_response(404)
          refute d.slug in slugs(user)
        end

        for user <- [author, staff] do
          %{"discussion" => shown} =
            api(:get, "/api/discussions/#{d.slug}", user) |> json_response(200)

          assert shown["status"] == status
          assert shown["moderation_reason"] == "Spoilers for the final chapter"
          assert d.slug in slugs(user)
        end

        # pas d'interaction possible pour les autres
        assert api(:put, "/api/discussions/#{d.slug}/vote", other) |> json_response(404)

        assert api(:post, "/api/discussions/#{d.slug}/replies", other, %{"body" => "Hello there"})
               |> json_response(404)

        # ni d'édition par l'auteur d'un contenu modéré
        assert %{"error" => "forbidden"} =
                 api(:patch, "/api/discussions/#{d.slug}", author, %{"title" => "Sneaky edit"})
                 |> json_response(403)
      end
    end

    test "hidden replies: excluded from the page and the counters for others", %{
      author: author,
      other: other,
      staff: staff
    } do
      d = discussion!(author)
      visible = reply!(other, d, "A helpful answer")
      hidden = reply!(other, d, "An answer with spoilers")
      set_status(hidden, "hidden")

      page = fn user ->
        %{"discussion" => shown, "replies" => %{"entries" => entries}} =
          api(:get, "/api/discussions/#{d.slug}", user) |> json_response(200)

        {shown["reply_count"], Enum.map(entries, &{&1["id"], &1["moderation_reason"]})}
      end

      assert page.(nil) == {1, [{visible.id, nil}]}
      assert page.(author) == {1, [{visible.id, nil}]}
      # l'auteur de la réponse et le staff la voient, avec le motif
      assert page.(other) ==
               {1, [{visible.id, nil}, {hidden.id, "Spoilers for the final chapter"}]}

      assert {1, [_, {_, "Spoilers for the final chapter"}]} = page.(staff)

      assert api(:put, "/api/replies/#{hidden.id}/vote", author) |> json_response(404)
    end
  end

  describe "blocks (social, both directions)" do
    test "content of blocked members is excluded from lists, pages, counters and actions", %{
      author: author,
      other: other
    } do
      reader = uuid()
      d_blocked = discussion!(author, %{"title" => "Written by a blocked member"})
      d_ok = discussion!(other, %{"title" => "Written by a friend"})
      reply_blocked = reply!(author, d_ok, "Reply by the blocked member")
      reply_ok = reply!(other, d_ok, "Reply by the friend")

      d_only_blocked = discussion!(other, %{"title" => "Only the blocked member answered"})
      reply!(author, d_only_blocked)

      # reader a bloqué author (le sens inverse donnerait le même résultat : social renvoie les deux sens)
      stub_services(blocks: [{reader, author}])

      assert slugs(reader) |> length() == 2
      refute d_blocked.slug in slugs(reader)
      assert api(:get, "/api/discussions/#{d_blocked.slug}", reader) |> json_response(404)

      %{"discussion" => shown, "replies" => %{"entries" => entries}} =
        api(:get, "/api/discussions/#{d_ok.slug}", reader) |> json_response(200)

      assert shown["reply_count"] == 1
      assert Enum.map(entries, & &1["id"]) == [reply_ok.id]

      # « sans réponse » : seules des réponses de membres bloqués → sans réponse pour ce lecteur
      assert slugs(reader, "filter=unanswered") == [d_only_blocked.slug]
      assert slugs(nil, "filter=unanswered") == [d_blocked.slug]

      assert api(:put, "/api/replies/#{reply_blocked.id}/vote", reader) |> json_response(404)

      assert api(:post, "/api/discussions/#{d_blocked.slug}/replies", reader, %{
               "body" => "Hi there"
             })
             |> json_response(404)

      assert %{"errors" => %{"target_id" => ["is invalid"]}} =
               api(:post, "/api/reports", reader, %{
                 "target_type" => "reply",
                 "target_id" => reply_blocked.id,
                 "reason" => "spam"
               })
               |> json_response(422)

      # le membre bloqué ne voit pas non plus le lecteur (deux sens)
      d_reader = discussion!(reader, %{"title" => "Written by the blocker"})
      assert api(:get, "/api/discussions/#{d_reader.slug}", author) |> json_response(404)
      # un visiteur voit tout
      assert length(slugs(nil)) == 4
    end

    @tag :capture_log
    test "social unreachable: members get 503 blocks_unavailable, visitors still read", %{
      author: author
    } do
      d = discussion!(author)
      member = uuid()
      stub_services(down: ["social"])

      for {method, path, body} <- [
            {:get, "/api/discussions", nil},
            {:get, "/api/discussions/#{d.slug}", nil},
            {:post, "/api/discussions/#{d.slug}/replies", %{"body" => "Hello there"}},
            {:put, "/api/discussions/#{d.slug}/vote", nil}
          ] do
        assert %{"error" => "blocks_unavailable"} =
                 api(method, path, member, body) |> json_response(503)
      end

      assert %{"entries" => [_]} = api(:get, "/api/discussions", nil) |> json_response(200)
      assert api(:get, "/api/discussions/#{d.slug}", nil) |> json_response(200)
      assert Repo.aggregate(Reply, :count) == 0
      assert Repo.get!(Discussion, d.id).helpful_count == 0
    end
  end
end
