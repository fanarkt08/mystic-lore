defmodule MlLearningWeb.GamificationApiTest do
  use MlLearningWeb.ConnCase, async: true

  @badge_keys ~w(description icon id name rarity slug)
  @achievement_keys Enum.sort(
                      @badge_keys ++
                        ~w(criterion earned earned_at equipped position progress)
                    )
  @quest_keys ~w(completed description id kind progress slug target title xp_reward)

  setup do
    xp = badge_fixture(name: "Cent runes", criterion: "total_xp", target: 100, position: 1)

    first =
      badge_fixture(
        name: "Première étincelle",
        criterion: "lessons_completed",
        target: 1,
        icon: "hero-sparkles",
        position: 2
      )

    duel =
      badge_fixture(
        name: "Première victoire",
        criterion: "multiplayer_wins",
        target: 1,
        icon: "hero-users",
        rarity: "uncommon",
        position: 3
      )

    [story, other] =
      adventure_fixture(%{}, [[%{xp_reward: 10}, %{xp_reward: 15}]]) |> lessons_of()

    %{user: user_id(), xp: xp, first: first, duel: duel, story: story, other: other}
  end

  defp internal_xp(user, ref_key, amount) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign("multiplayer"))
    |> post("/api/internal/xp", %{"user_id" => user, "ref_key" => ref_key, "amount" => amount})
    |> json_response(200)
  end

  defp equip(conn, user, ids),
    do: conn |> as_user(user) |> put("/api/me/badges/equipped", %{"badge_ids" => ids})

  test "user routes need a user in the token; the public profile does not", %{
    conn: conn,
    user: user
  } do
    for {method, path} <- [
          {:get, "/api/me/achievements"},
          {:put, "/api/me/badges/equipped"},
          {:get, "/api/me/quests"}
        ] do
      conn = dispatch(as_service(conn), @endpoint, method, path, %{})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}, "#{method} #{path}"
    end

    assert json_response(get(conn, "/api/users/#{user}/profile"), 401)
    assert json_response(get(as_service(conn), "/api/users/#{user}/profile"), 200)
  end

  test "achievements: earned and locked badges with progress, nothing equipped yet", %{
    conn: conn,
    user: user,
    story: story
  } do
    json_response(post(as_user(conn, user), "/api/lessons/#{story.id}/complete"), 200)

    body = json_response(get(as_user(conn, user), "/api/me/achievements"), 200)
    assert %{"equipped" => [], "max_equipped" => 3, "badges" => [xp, first, duel]} = body
    assert Enum.sort(Map.keys(first)) == @achievement_keys

    assert %{
             "name" => "Première étincelle",
             "icon" => "hero-sparkles",
             "rarity" => "common",
             "criterion" => "lessons_completed",
             "earned" => true,
             "equipped" => false,
             "position" => nil,
             "progress" => %{"current" => 1, "target" => 1}
           } = first

    assert {:ok, _, 0} = DateTime.from_iso8601(first["earned_at"])

    assert %{
             "earned" => false,
             "earned_at" => nil,
             "progress" => %{"current" => 10, "target" => 100}
           } = xp

    assert %{"earned" => false, "criterion" => "multiplayer_wins", "rarity" => "uncommon"} = duel
  end

  test "the multiplayer badge is earned through /api/internal/xp", %{
    conn: conn,
    user: user,
    duel: duel
  } do
    assert internal_xp(user, "multiplayer:match:42", 30) == %{"xp" => "awarded"}
    assert internal_xp(user, "multiplayer:match:42", 30) == %{"xp" => "duplicate"}

    %{"badges" => badges} = json_response(get(as_user(conn, user), "/api/me/achievements"), 200)
    assert %{"earned" => true} = Enum.find(badges, &(&1["id"] == duel.id))
  end

  test "PUT /api/me/badges/equipped replaces the list in order and answers the new state", ctx do
    %{conn: conn, user: user, first: first, duel: duel, story: story} = ctx
    json_response(post(as_user(conn, user), "/api/lessons/#{story.id}/complete"), 200)
    internal_xp(user, "multiplayer:match:1", 30)

    body = conn |> equip(user, [duel.id, first.id]) |> json_response(200)

    assert Enum.map(body["equipped"], &{&1["id"], &1["position"]}) == [
             {duel.id, 1},
             {first.id, 2}
           ]

    assert Enum.sort(Map.keys(hd(body["equipped"]))) == Enum.sort(@badge_keys ++ ["position"])

    assert %{"equipped" => true, "position" => 2} =
             Enum.find(body["badges"], &(&1["id"] == first.id))

    # réordonner, puis tout déséquiper
    body = conn |> equip(user, [first.id, duel.id]) |> json_response(200)
    assert Enum.map(body["equipped"], & &1["id"]) == [first.id, duel.id]
    assert %{"equipped" => []} = conn |> equip(user, []) |> json_response(200)
  end

  test "PUT errors: more than 3, a badge not earned, malformed ids", ctx do
    %{conn: conn, user: user, xp: xp, first: first, duel: duel, story: story} = ctx
    json_response(post(as_user(conn, user), "/api/lessons/#{story.id}/complete"), 200)
    extra = badge_fixture(criterion: "total_xp", target: 1)
    internal_xp(user, "multiplayer:match:1", 100)

    assert conn |> equip(user, [xp.id, first.id, duel.id, extra.id]) |> json_response(422) ==
             %{"error" => "equip_limit_exceeded"}

    locked = badge_fixture(criterion: "level", target: 9)

    assert conn |> equip(user, [first.id, locked.id]) |> json_response(422) ==
             %{"error" => "badge_not_earned"}

    for bad <- [[first.id, first.id], ["x"], "#{first.id}"] do
      assert %{"error" => "invalid", "errors" => %{"badge_ids" => [_]}} =
               conn |> equip(user, bad) |> json_response(422)
    end

    assert %{"error" => "invalid"} =
             conn |> as_user(user) |> put("/api/me/badges/equipped", %{}) |> json_response(422)

    assert %{"equipped" => []} =
             json_response(get(as_user(conn, user), "/api/me/achievements"), 200)
  end

  test "GET /api/me/quests settles the day's quests at read time, once", %{
    conn: conn,
    user: user,
    story: story
  } do
    lesson_quest = quest_fixture(kind: "lessons_completed", target: 1, xp_reward: 15, position: 1)
    xp_quest = quest_fixture(kind: "xp_earned", target: 30, xp_reward: 20, position: 2)

    # leçon terminée : sa quête est réglée tout de suite (+15) ; les 15 XP de quête ne comptent pas pour « 30 XP »
    json_response(post(as_user(conn, user), "/api/lessons/#{story.id}/complete"), 200)

    body = json_response(get(as_user(conn, user), "/api/me/quests"), 200)
    today = Date.utc_today()
    assert body["date"] == Date.to_iso8601(today)
    assert body["resets_at"] == "#{Date.add(today, 1)}T00:00:00Z"
    assert [lesson, xp] = body["quests"]
    assert Enum.sort(Map.keys(lesson)) == @quest_keys
    assert %{"id" => id, "completed" => true, "progress" => 1, "xp_reward" => 15} = lesson
    assert id == lesson_quest.id
    assert %{"completed" => false, "progress" => 10, "target" => 30} = xp

    # 25 XP de plus, hors leçon (ex. seeds, autre service) : réglée à la lecture suivante, une seule fois
    xp_event(user, "multiplayer:match:9", 25)
    xp_quest_id = xp_quest.id

    for _ <- 1..2 do
      assert [%{"completed" => true}, %{"id" => ^xp_quest_id, "completed" => true}] =
               json_response(get(as_user(conn, user), "/api/me/quests"), 200)["quests"]
    end

    # 10 (leçon) + 25 + 15 + 20 (récompenses)
    assert %{"xp" => 70} = json_response(get(as_user(conn, user), "/api/me/dashboard"), 200)
  end

  test "saving a note completes the note quest", %{conn: conn, user: user, other: lesson} do
    quest_fixture(kind: "note_written", target: 1, xp_reward: 10)
    user_conn = as_user(conn, user)

    assert response(put(user_conn, "/api/lessons/#{lesson.id}/notes", notes: "Loops!"), 204)

    assert [%{"completed" => true, "progress" => 1}] =
             json_response(get(user_conn, "/api/me/quests"), 200)["quests"]
  end

  test "dashboard keeps its shape and adds today's quests and equipped badges", ctx do
    %{conn: conn, user: user, first: first, story: story} = ctx
    quest_fixture(kind: "xp_earned", target: 30, xp_reward: 20)
    user_conn = as_user(conn, user)
    json_response(post(user_conn, "/api/lessons/#{story.id}/complete"), 200)
    xp_event(user, "community:answer:3", 40)
    conn |> equip(user, [first.id]) |> json_response(200)

    body = json_response(get(user_conn, "/api/me/dashboard"), 200)

    # la quête « 30 XP » est réglée avant le calcul : 10 + 40 + 20 XP
    assert %{"xp" => 70, "level" => 1, "badges_earned" => 1, "badges_total" => 3} = body
    assert [%{"completed" => true, "kind" => "xp_earned"}] = body["quests"]

    assert [%{"id" => id, "position" => 1, "name" => "Première étincelle"}] =
             body["equipped_badges"]

    assert id == first.id
    assert List.last(body["week"])["xp"] == 70
  end

  test "public profile: readable by anyone, never needs to be the member", ctx do
    %{conn: conn, user: user, first: first, story: story, other: other} = ctx
    user_conn = as_user(conn, user)
    json_response(post(user_conn, "/api/lessons/#{story.id}/complete"), 200)
    json_response(post(user_conn, "/api/lessons/#{other.id}/complete"), 200)
    conn |> equip(user, [first.id]) |> json_response(200)

    expected = %{
      "user_id" => user,
      "level" => 1,
      # 10 + 15 + 50 de bonus de fin d'aventure
      "xp" => 75,
      "badges_earned" => 1,
      "adventures_completed" => 1,
      "equipped_badges" => [
        %{
          "id" => first.id,
          "slug" => first.slug,
          "name" => "Première étincelle",
          "description" => "A test badge.",
          "icon" => "hero-sparkles",
          "rarity" => "common",
          "position" => 1
        }
      ]
    }

    stranger = user_id()

    for caller <- [as_user(build_conn(), stranger), as_service(build_conn())] do
      assert json_response(get(caller, "/api/users/#{user}/profile"), 200) == expected
    end

    assert %{"xp" => 0, "level" => 1, "equipped_badges" => [], "badges_earned" => 0} =
             json_response(get(as_service(conn), "/api/users/#{stranger}/profile"), 200)

    for id <- ["nope", "1"] do
      assert json_response(get(as_service(conn), "/api/users/#{id}/profile"), 404) == %{
               "error" => "not_found"
             }
    end
  end
end
