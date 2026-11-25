defmodule MlAccountsWeb.ActiveSessionsTest do
  use MlAccountsWeb.ConnCase, async: true
  import Ecto.Query, only: [where: 2]
  alias MlAccounts.Session

  setup do
    user = user_fixture()
    MlShared.Events.subscribe("user:#{user.id}")
    %{user: user}
  end

  defp as(user, token), do: build_conn() |> internal(user.id) |> with_session(token)
  defp valid_session?(token), do: MlAccounts.get_session_user(token) != nil

  describe "device of a new session" do
    test "user agent truncated and cleaned, IP anonymised (IPv4 /24, IPv6 /48)", %{user: user} do
      session_fixture(user, %{user_agent: String.duplicate("a", 300), ip: "198.51.100.23"})

      session_fixture(user, %{
        user_agent: "Firefox\u0000\n/140",
        ip: "2001:db8:85a3:8d3:1319:8a2e:370:7348"
      })

      session_fixture(user, %{user_agent: <<"bad", 255>>, ip: "::ffff:192.0.2.128"})
      session_fixture(user, %{user_agent: " ", ip: "not an ip"})
      session_fixture(user)

      devices = Session |> Repo.all() |> Enum.map(&{&1.user_agent, &1.ip}) |> Enum.sort()

      assert devices ==
               Enum.sort([
                 {String.duplicate("a", 200), "198.51.100.0"},
                 {"Firefox/140", "2001:db8:85a3::"},
                 {"bad", "192.0.2.0"},
                 {nil, nil},
                 {nil, nil}
               ])
    end
  end

  describe "GET /api/me/sessions" do
    test "lists the member's valid sessions, most recent first, flagging the current one", %{
      user: user
    } do
      old = session_fixture(user, %{user_agent: "Old browser", ip: "192.0.2.1"})
      current = session_fixture(user, %{user_agent: "This browser", ip: "192.0.2.2"})
      expired = session_fixture(user)
      session_fixture(user_fixture())

      Repo.update_all(where(Session, token_hash: ^:crypto.hash(:sha256, old)),
        set: [last_used_at: DateTime.add(DateTime.utc_now(:second), -3600)]
      )

      Repo.update_all(where(Session, token_hash: ^:crypto.hash(:sha256, expired)),
        set: [last_used_at: DateTime.add(DateTime.utc_now(:second), -30, :day)]
      )

      assert %{"sessions" => [first, second]} =
               user |> as(current) |> get("/api/me/sessions") |> json_response(200)

      assert %{"user_agent" => "This browser", "ip" => "192.0.2.0", "current" => true} = first
      assert %{"user_agent" => "Old browser", "current" => false} = second

      assert Map.keys(first) |> Enum.sort() ==
               ~w(current id inserted_at ip last_used_at user_agent)
    end
  end

  describe "DELETE /api/me/sessions/:id" do
    setup %{user: user} do
      current = session_fixture(user)
      other = session_fixture(user)

      [other_id] =
        for s <- Repo.all(Session), s.token_hash == :crypto.hash(:sha256, other), do: s.id

      [current_id] =
        for s <- Repo.all(Session), s.token_hash == :crypto.hash(:sha256, current), do: s.id

      %{current: current, other: other, other_id: other_id, current_id: current_id}
    end

    test "revokes another session of the member and publishes the event", %{
      user: user,
      current: current,
      other: other,
      other_id: other_id
    } do
      assert user |> as(current) |> delete("/api/me/sessions/#{other_id}") |> response(204)
      refute valid_session?(other)
      assert valid_session?(current)
      assert_receive {:sessions_revoked, user_id}
      assert user_id == user.id
    end

    test "the current session is protected", %{user: user, current: current, current_id: id} do
      assert %{"error" => "current_session"} =
               user |> as(current) |> delete("/api/me/sessions/#{id}") |> json_response(409)

      assert valid_session?(current)
      refute_received {:sessions_revoked, _}
    end

    test "someone else's, unknown or malformed ids are not found", %{
      other: other,
      other_id: other_id
    } do
      intruder = user_fixture()

      for id <- [other_id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert %{"error" => "not_found"} =
                 intruder
                 |> as(session_fixture(intruder))
                 |> delete("/api/me/sessions/#{id}")
                 |> json_response(404)
      end

      assert valid_session?(other)
    end
  end

  describe "DELETE /api/me/sessions" do
    test "signs out every other session of the member only", %{user: user} do
      current = session_fixture(user)
      others = [session_fixture(user), session_fixture(user)]
      someone_else = session_fixture(user_fixture())

      assert user |> as(current) |> delete("/api/me/sessions") |> response(204)

      assert valid_session?(current)
      refute Enum.any?(others, &valid_session?/1)
      assert valid_session?(someone_else)
      assert_receive {:sessions_revoked, _}
    end
  end

  describe "other revocations publish {:sessions_revoked, user_id}" do
    test "logout (DELETE /api/sessions/current)", %{user: user} do
      token = session_fixture(user)

      assert build_conn()
             |> internal()
             |> with_session(token)
             |> delete("/api/sessions/current")
             |> response(204)

      assert_receive {:sessions_revoked, user_id}
      assert user_id == user.id
    end

    test "password change", %{user: user} do
      current = session_fixture(user)

      assert user
             |> as(current)
             |> put("/api/me/password", %{
               current_password: password(),
               password: "brand new passphrase"
             })
             |> response(204)

      assert_receive {:sessions_revoked, _}
    end
  end
end
