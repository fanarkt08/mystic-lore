defmodule MlAccountsWeb.SessionControllerTest do
  use MlAccountsWeb.ConnCase, async: true
  alias MlAccounts.{LoginFailure, Session}

  @wrong "definitely the wrong one"

  defp login(email, password),
    do: build_conn() |> internal() |> post("/api/sessions", %{email: email, password: password})

  defp current(token),
    do: build_conn() |> internal() |> with_session(token) |> get("/api/sessions/current")

  defp logout(token),
    do: build_conn() |> internal() |> with_session(token) |> delete("/api/sessions/current")

  defp ago(amount, unit), do: DateTime.add(DateTime.utc_now(:second), -amount, unit)

  describe "POST /api/sessions" do
    test "opens a session and stores only the token's SHA-256" do
      user = user_fixture()

      assert %{
               "session_token" => token,
               "user" => %{"id" => id, "confirmed" => true, "email" => email}
             } =
               login(" " <> String.upcase(user.email), password()) |> json_response(201)

      assert {id, email} == {user.id, user.email}
      assert {:ok, raw} = Base.url_decode64(token, padding: false)
      assert byte_size(raw) == 32
      assert [%Session{token_hash: hash}] = Repo.all(Session)
      assert hash == :crypto.hash(:sha256, token)
    end

    test "rejects bad credentials without revealing whether the email exists" do
      user = user_fixture()
      assert %{"error" => "invalid_credentials"} = login(user.email, @wrong) |> json_response(401)

      assert %{"error" => "invalid_credentials"} =
               login("ghost@example.test", password()) |> json_response(401)

      assert %{"error" => "invalid_credentials"} = login(nil, nil) |> json_response(401)
    end

    test "an unconfirmed account gets 403 only when the password is right" do
      user = user_fixture(confirmed: false)
      assert %{"error" => "invalid_credentials"} = login(user.email, @wrong) |> json_response(401)
      assert %{"error" => "unconfirmed"} = login(user.email, password()) |> json_response(403)
      assert Repo.all(Session) == []
    end

    test "5 failures in 15 minutes lock the email (429), even with the right password" do
      user = user_fixture()

      for _ <- 1..5,
          do:
            assert(
              %{"error" => "invalid_credentials"} =
                login(user.email, @wrong) |> json_response(401)
            )

      assert %{"error" => "locked"} = login(user.email, password()) |> json_response(429)

      assert %{"error" => "locked"} =
               login(String.upcase(user.email), @wrong) |> json_response(429)

      assert Repo.aggregate(LoginFailure, :count) == 5

      other = user_fixture()
      assert login(other.email, password()) |> json_response(201)

      Repo.update_all(LoginFailure, set: [inserted_at: ago(15, :minute)])
      assert login(user.email, password()) |> json_response(201)
    end

    test "the lock also applies to unknown emails" do
      for _ <- 1..5, do: login("ghost@example.test", @wrong)
      assert %{"error" => "locked"} = login("ghost@example.test", @wrong) |> json_response(429)
    end

    test "a correct password resets the failure counter" do
      user = user_fixture()
      for _ <- 1..4, do: login(user.email, @wrong)
      assert login(user.email, password()) |> json_response(201)

      for _ <- 1..5, do: assert(login(user.email, @wrong) |> json_response(401))
      assert login(user.email, password()) |> json_response(429)
    end
  end

  describe "GET and DELETE /api/sessions/current" do
    setup do
      user = user_fixture()
      %{user: user, token: session_fixture(user)}
    end

    test "returns the private user of the session", %{user: user, token: token} do
      assert %{"user" => %{"id" => id, "email" => email, "role" => "user", "confirmed" => true}} =
               current(token) |> json_response(200)

      assert {id, email} == {user.id, user.email}
    end

    test "401 for a missing or unknown token", %{token: token} do
      assert %{"error" => "unauthorized"} =
               build_conn() |> internal() |> get("/api/sessions/current") |> json_response(401)

      assert %{"error" => "unauthorized"} = current(token <> "x") |> json_response(401)
    end

    test "DELETE revokes the session (idempotent)", %{token: token} do
      assert logout(token) |> response(204) == ""
      assert %{"error" => "unauthorized"} = current(token) |> json_response(401)
      assert Repo.all(Session) == []
      assert logout(token) |> response(204)
      assert build_conn() |> internal() |> delete("/api/sessions/current") |> response(204)
    end

    test "expires after 30 days without use; every use slides the expiry", %{token: token} do
      Repo.update_all(Session, set: [last_used_at: ago(29, :day)])
      assert current(token) |> json_response(200)
      assert [%Session{last_used_at: last_used_at}] = Repo.all(Session)
      assert DateTime.diff(DateTime.utc_now(), last_used_at) < 5

      Repo.update_all(Session, set: [last_used_at: ago(30, :day)])
      assert %{"error" => "unauthorized"} = current(token) |> json_response(401)
    end
  end
end
