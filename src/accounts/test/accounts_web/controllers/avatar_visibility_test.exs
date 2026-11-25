defmodule MlAccountsWeb.AvatarVisibilityTest do
  use MlAccountsWeb.ConnCase, async: true
  import Ecto.Query, only: [from: 2]
  import MlShared.ImageFixtures
  alias MlAccounts.{AuditEntry, Profiles, User}

  @moduletag :capture_log

  defp as(user), do: build_conn() |> internal(user && user.id)

  defp upload(user, bytes) do
    user
    |> as()
    |> put_req_header("content-type", "application/octet-stream")
    |> put("/api/me/avatar", bytes)
  end

  defp avatar_file(name),
    do: Path.join([Application.fetch_env!(:accounts, :storage_dir), "avatars", name])

  describe "avatar" do
    setup do
      user = user_fixture()
      MlShared.Events.subscribe("user:#{user.id}")
      %{user: user}
    end

    test "an uploaded image is stored without metadata under a random name, then served", %{
      user: user
    } do
      jpeg = jpeg(128, 128, [jfif(), exif_gps(), xmp_jpeg()])

      assert %{"user" => %{"avatar" => %{"kind" => "image", "key" => name}}} =
               upload(user, jpeg) |> json_response(200)

      assert name =~ ~r/\A[0-9a-f]{32}\.jpg\z/
      assert_receive {:profile_changed, _}
      stored = File.read!(avatar_file(name))
      refute stored =~ "Exif" or stored =~ "SECRET"

      conn = build_conn() |> internal() |> get("/api/avatars/#{name}")
      assert response(conn, 200) == stored
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      # l'identité publique porte l'avatar (pas la bio)
      assert %{"users" => [%{"avatar" => %{"kind" => "image", "key" => ^name}} = public]} =
               build_conn()
               |> internal()
               |> get("/api/users?ids=#{user.id}")
               |> json_response(200)

      refute Map.has_key?(public, "bio")
    end

    test "refusals: signature, size, dimensions; nothing is stored", %{user: user} do
      assert %{"errors" => %{"avatar" => ["must be a PNG, JPEG or WebP image"]}} =
               upload(user, "plain text renamed to avatar.png") |> json_response(422)

      assert %{"errors" => %{"avatar" => ["must be at most 2 MB"]}} =
               upload(user, png() <> :binary.copy(<<0>>, 2_100_000)) |> json_response(422)

      assert %{"errors" => %{"avatar" => ["must be between 64 and 2048 pixels wide and high"]}} =
               upload(user, png(32, 32)) |> json_response(422)

      assert %{"errors" => %{"avatar" => ["is not a valid image file"]}} =
               upload(user, binary_part(png(), 0, 60)) |> json_response(422)

      assert Repo.reload!(user).avatar_image == nil
    end

    test "replacing, choosing a crest or removing deletes the previous file", %{user: user} do
      %{"user" => %{"avatar" => %{"key" => first}}} = upload(user, png()) |> json_response(200)

      %{"user" => %{"avatar" => %{"key" => second}}} =
        upload(user, webp_vp8l()) |> json_response(200)

      refute File.exists?(avatar_file(first))
      assert File.exists?(avatar_file(second))
      assert build_conn() |> internal() |> get("/api/avatars/#{first}") |> response(404)

      assert %{"errors" => %{"crest" => ["is invalid"]}} =
               user |> as() |> put("/api/me/avatar/crest", %{crest: "owl"}) |> json_response(422)

      assert %{"user" => %{"avatar" => %{"kind" => "crest", "key" => "moon"}}} =
               user |> as() |> put("/api/me/avatar/crest", %{crest: "moon"}) |> json_response(200)

      refute File.exists?(avatar_file(second))

      assert %{"user" => %{"avatar" => nil}} =
               user |> as() |> delete("/api/me/avatar") |> json_response(200)

      # noms invalides : jamais de lecture hors du dossier
      for name <- ["../../../etc/passwd", "x.png", String.duplicate("a", 32) <> ".gif"] do
        assert build_conn()
               |> internal()
               |> get("/api/avatars/#{URI.encode_www_form(name)}")
               |> response(404)
      end
    end

    test "staff reset: reason required, audited, moderators and admins only", %{user: user} do
      %{"user" => %{"avatar" => %{"key" => name}}} = upload(user, png()) |> json_response(200)
      moderator = user_fixture() |> Ecto.Changeset.change(role: "moderator") |> Repo.update!()
      member = user_fixture()

      reset = fn by, body ->
        by
        |> as()
        |> put_req_header("content-type", "application/json")
        |> post("/api/admin/users/#{user.id}/avatar/reset", Jason.encode!(body))
      end

      assert reset.(member, %{reason: "inappropriate image"}) |> json_response(403)

      assert %{"errors" => %{"reason" => [_]}} =
               reset.(moderator, %{reason: "bad"}) |> json_response(422)

      assert File.exists?(avatar_file(name))

      assert %{"user" => %{"avatar" => nil}} =
               reset.(moderator, %{reason: "Offensive symbol in the picture"})
               |> json_response(200)

      refute File.exists?(avatar_file(name))
      assert_receive {:profile_changed, _}

      assert [entry] =
               Repo.all(from e in AuditEntry, where: e.action == "accounts.avatar.reset")

      assert {entry.actor_id, entry.target_id, entry.metadata} ==
               {moderator.id, user.id, %{"kind" => "image"}}

      assert entry.reason == "Offensive symbol in the picture"

      # rien à réinitialiser : aucune nouvelle entrée
      assert reset.(moderator, %{reason: "Offensive symbol in the picture"}) |> json_response(200)

      assert Repo.aggregate(
               from(e in AuditEntry, where: e.action == "accounts.avatar.reset"),
               :count
             ) == 1
    end
  end

  describe "profile visibility" do
    setup do
      owner =
        user_fixture(%{display_name: "Sarah Lefèvre"})
        |> Ecto.Changeset.change(
          bio: "Archivist at heart.",
          pronouns: "she/they",
          interests: ["history"],
          cover: "archive"
        )
        |> Repo.update!()

      friend = user_fixture()
      blocked = user_fixture()

      # faux social : `friend` est ami du propriétaire ; `blocked` l'était mais un blocage existe
      test = self()

      Req.Test.stub(MlShared.Client, fn conn ->
        %{"a" => a, "b" => b} = URI.decode_query(conn.query_string)
        send(test, {:relationship, a, b})
        pair = MapSet.new([a, b])

        Req.Test.json(conn, %{
          "friends" =>
            pair in [MapSet.new([owner.id, friend.id]), MapSet.new([owner.id, blocked.id])],
          "blocked" => pair == MapSet.new([owner.id, blocked.id])
        })
      end)

      %{owner: owner, friend: friend, blocked: blocked, member: user_fixture()}
    end

    defp profile(owner, reader) do
      reader
      |> as()
      |> get("/api/users/by-username/#{owner.username}/profile")
      |> json_response(200)
      |> Map.fetch!("profile")
    end

    defp set_visibility(owner, visibility),
      do:
        owner
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.force_change(:profile_visibility, visibility)
        |> Repo.update!()

    test "matrix: visitor, member, friend, blocked, self × public, members, friends, private",
         ctx do
      readers = [
        visitor: nil,
        member: ctx.member,
        friend: ctx.friend,
        blocked: ctx.blocked,
        self: ctx.owner
      ]

      expected = %{
        "public" => [:visitor, :member, :friend, :blocked, :self],
        "members" => [:member, :friend, :blocked, :self],
        "friends" => [:friend, :self],
        "private" => [:self]
      }

      for {visibility, allowed} <- expected, {name, reader} <- readers do
        owner = set_visibility(ctx.owner, visibility)
        seen = profile(owner, reader)

        # l'identité reste toujours visible
        assert %{
                 "username" => _,
                 "display_name" => "Sarah Lefèvre",
                 "avatar" => nil,
                 "cover" => "archive"
               } =
                 seen

        assert seen["visibility"] == visibility

        if name in allowed do
          assert seen["details"] == %{
                   "bio" => "Archivist at heart.",
                   "pronouns" => "she/they",
                   "interests" => ["history"]
                 },
                 "#{name} should see a #{visibility} profile"

          assert seen["academy_record"] == true
        else
          assert seen["details"] == nil, "#{name} should not see a #{visibility} profile"
          assert seen["academy_record"] == false
        end
      end
    end

    test "social is asked only for a `friends` profile; unreachable social means not a friend",
         ctx do
      owner = set_visibility(ctx.owner, "members")
      profile(owner, ctx.member)
      refute_received {:relationship, _, _}

      owner = set_visibility(owner, "friends")
      profile(owner, ctx.friend)
      assert_received {:relationship, a, b}
      assert {a, b} == {owner.id, ctx.friend.id}

      Req.Test.stub(MlShared.Client, &Req.Test.transport_error(&1, :econnrefused))
      assert profile(owner, ctx.friend)["details"] == nil
    end

    test "an unknown or deleted reader is a visitor; unknown profiles are 404", ctx do
      owner = set_visibility(ctx.owner, "members")

      gone =
        user_fixture()
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
        |> Repo.update!()

      assert profile(owner, %User{id: Ecto.UUID.generate()})["details"] == nil
      assert profile(owner, gone)["details"] == nil

      assert build_conn()
             |> internal()
             |> get("/api/users/by-username/nobody/profile")
             |> json_response(404)
    end

    test "the preview equals what a real reader of each category receives", ctx do
      for visibility <- User.visibilities() do
        owner = set_visibility(ctx.owner, visibility)

        for {as, reader} <- [visitor: nil, member: ctx.member, friend: ctx.friend] do
          preview =
            owner
            |> as()
            |> get("/api/me/profile-preview", as: Atom.to_string(as))
            |> json_response(200)
            |> Map.fetch!("profile")

          assert preview == profile(owner, reader), "preview as #{as} of a #{visibility} profile"
        end
      end

      assert %{"errors" => %{"as" => ["is invalid"]}} =
               ctx.owner
               |> as()
               |> get("/api/me/profile-preview", as: "self")
               |> json_response(422)
    end

    test "view/2 is the single filter: same function for the page and the preview", ctx do
      owner = set_visibility(ctx.owner, "friends")
      assert Profiles.view(owner, :friend) == Profiles.for_reader(owner, ctx.friend.id)
      assert Profiles.view(owner, :member) == Profiles.for_reader(owner, ctx.blocked.id)
    end
  end
end
