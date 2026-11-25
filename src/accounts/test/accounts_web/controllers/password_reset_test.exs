defmodule MlAccountsWeb.PasswordResetTest do
  use MlAccountsWeb.ConnCase, async: true
  alias MlAccounts.{LoginFailure, Session, UserToken}

  @new_password "a fresh new passphrase"

  defp request(email),
    do: build_conn() |> internal() |> post("/api/password-resets", %{email: email})

  defp check(token), do: build_conn() |> internal() |> get("/api/password-resets/#{token}")

  defp reset(token, password),
    do: build_conn() |> internal() |> post("/api/password-resets/#{token}", %{password: password})

  defp emailed_reset_token do
    assert_received {:email, email}
    assert email.subject == "Reset your MysticLore password"

    [_, token] =
      Regex.run(~r{http://localhost:4000/reset-password/([A-Za-z0-9_-]+)\n}, email.text_body)

    token
  end

  defp valid_session?(token), do: MlAccounts.get_session_user(token) != nil
  defp ago(amount, unit), do: DateTime.add(DateTime.utc_now(:second), -amount, unit)

  describe "POST /api/password-resets" do
    test "always answers 204 with an empty body; only existing accounts get an email" do
      user = user_fixture()

      responses =
        for email <- ["nobody@example.test", nil, String.upcase(" #{user.email} ")] do
          conn = request(email)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(responses) == [{204, ""}]

      assert_received {:email, email}
      assert email.to == [{user.display_name, user.email}]
      refute_received {:email, _}
    end

    test "stores only the token's SHA-256, valid for 1 hour" do
      user = user_fixture()
      request(user.email)
      token = emailed_reset_token()

      assert [%UserToken{context: "reset_password", token_hash: hash, sent_to: sent_to}] =
               Repo.all(UserToken)

      assert hash == :crypto.hash(:sha256, token)
      assert sent_to == user.email
      assert check(token) |> response(204)

      Repo.update_all(UserToken, set: [inserted_at: ago(60, :minute)])
      assert %{"error" => "not_found"} = check(token) |> json_response(404)
      assert %{"error" => "not_found"} = check("unknown-token") |> json_response(404)
    end

    test "sends at most 3 reset emails per hour per account" do
      user = user_fixture()
      for _ <- 1..4, do: assert(request(user.email) |> response(204))
      for _ <- 1..3, do: assert_received({:email, _})
      refute_received {:email, _}
    end
  end

  describe "POST /api/password-resets/:token" do
    setup do
      user = user_fixture()
      sessions = [session_fixture(user), session_fixture(user)]
      other = session_fixture(user_fixture())
      request(user.email)
      %{user: user, sessions: sessions, other: other, token: emailed_reset_token()}
    end

    test "sets the new password, revokes ALL the member's sessions and publishes the event", %{
      user: user,
      sessions: sessions,
      other: other,
      token: token
    } do
      MlShared.Events.subscribe("user:#{user.id}")

      assert reset(token, @new_password) |> response(204) == ""

      refute Enum.any?(sessions, &valid_session?/1)
      assert valid_session?(other)
      assert_receive {:sessions_revoked, user_id}
      assert user_id == user.id

      assert {:error, :invalid_credentials} = MlAccounts.login(user.email, password())
      assert {:ok, _token, _user} = MlAccounts.login(user.email, @new_password)
    end

    test "the link is single use and every other reset link dies with it", %{
      user: user,
      token: token
    } do
      request(user.email)
      second = emailed_reset_token()

      assert reset(token, @new_password) |> response(204)

      assert %{"error" => "not_found"} =
               reset(token, "yet another passphrase") |> json_response(404)

      assert %{"error" => "not_found"} =
               reset(second, "yet another passphrase") |> json_response(404)

      assert Repo.all(UserToken) == []
    end

    test "an invalid password is refused (422) without consuming the link", %{token: token} do
      assert %{"errors" => %{"password" => ["should be at least 12 character(s)"]}} =
               reset(token, "short") |> json_response(422)

      assert reset(token, @new_password) |> response(204)
    end

    test "expired (1 hour) or unknown links are not found", %{token: token} do
      assert %{"error" => "not_found"} = reset("unknown", @new_password) |> json_response(404)
      Repo.update_all(UserToken, set: [inserted_at: ago(60, :minute)])
      assert %{"error" => "not_found"} = reset(token, @new_password) |> json_response(404)
    end

    test "a link sent to a previous address stops working", %{user: user, token: token} do
      user |> Ecto.Changeset.change(email: "moved@example.test") |> Repo.update!()
      assert %{"error" => "not_found"} = reset(token, @new_password) |> json_response(404)
    end

    test "lifts the sign-in lock and confirms the email it reached", %{user: user, token: token} do
      user |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()
      for _ <- 1..5, do: MlAccounts.login(user.email, "definitely the wrong one")
      assert {:error, :locked} = MlAccounts.login(user.email, password())

      assert reset(token, @new_password) |> response(204)

      assert Repo.all(LoginFailure) == []

      assert {:ok, _token, %{confirmed_at: %DateTime{}}} =
               MlAccounts.login(user.email, @new_password)
    end

    test "does not bypass two-factor authentication", %{user: user} do
      {user, _secret, _codes} = two_factor_fixture(user)
      request(user.email)

      assert reset(emailed_reset_token(), @new_password) |> response(204)
      assert {:two_factor, _challenge, _user} = MlAccounts.login(user.email, @new_password)
      assert Repo.all(Session) |> Enum.filter(&(&1.user_id == user.id)) == []
    end
  end
end
