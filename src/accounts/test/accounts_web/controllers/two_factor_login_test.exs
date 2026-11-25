defmodule MlAccountsWeb.TwoFactorLoginTest do
  use MlAccountsWeb.ConnCase, async: true
  alias MlAccounts.{LoginChallenge, Session}

  setup do
    {user, secret, codes} = two_factor_fixture(user_fixture())
    %{user: user, secret: secret, codes: codes}
  end

  defp login(email),
    do: build_conn() |> internal() |> post("/api/sessions", %{email: email, password: password()})

  defp second_step(challenge, code, headers \\ []) do
    conn =
      Enum.reduce(headers, build_conn() |> internal(), fn {k, v}, c -> put_req_header(c, k, v) end)

    post(conn, "/api/sessions/2fa", %{challenge: challenge, code: code})
  end

  defp ago(amount, unit), do: DateTime.add(DateTime.utc_now(:second), -amount, unit)

  test "the password alone returns a short-lived challenge instead of a session", %{user: user} do
    assert %{"two_factor_required" => true, "challenge" => challenge} =
             login(user.email) |> json_response(200)

    assert {:ok, raw} = Base.url_decode64(challenge, padding: false)
    assert byte_size(raw) == 32
    assert [%LoginChallenge{token_hash: hash, attempts: 0}] = Repo.all(LoginChallenge)
    assert hash == :crypto.hash(:sha256, challenge)
    assert Repo.all(Session) == []
  end

  test "a TOTP code completes the sign-in once, recording the device", %{
    user: user,
    secret: secret
  } do
    challenge = challenge_fixture(user)

    headers = [
      {"x-client-ua", "Mozilla/5.0 (Macintosh) Firefox/140.0"},
      {"x-client-ip", "203.0.113.77"}
    ]

    assert %{"session_token" => token, "user" => %{"id" => id}} =
             second_step(challenge, totp(secret), headers) |> json_response(201)

    assert id == user.id
    assert MlAccounts.get_session_user(token).id == user.id

    assert [%Session{user_agent: "Mozilla/5.0 (Macintosh) Firefox/140.0", ip: "203.0.113.0"}] =
             Repo.all(Session)

    assert %{"error" => "not_found"} =
             second_step(challenge, totp(secret, System.os_time(:second) + 30))
             |> json_response(404)
  end

  test "a recovery code completes the sign-in and is then spent", %{user: user, codes: [code | _]} do
    assert second_step(challenge_fixture(user), code) |> json_response(201)

    assert %{"error" => "invalid_code", "attempts_left" => 4} =
             second_step(challenge_fixture(user), code) |> json_response(401)
  end

  test "two simultaneous sign-ins with one recovery code: a single session", %{
    user: user,
    codes: [code | _]
  } do
    challenges = [challenge_fixture(user), challenge_fixture(user)]

    statuses =
      challenges
      |> Task.async_stream(&second_step(&1, code).status, max_concurrency: 2)
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.sort(statuses) == [201, 401]
    assert Repo.aggregate(Session, :count) == 1
  end

  test "5 attempts per challenge: then it is dead, even with the right code", %{
    user: user,
    secret: secret
  } do
    challenge = challenge_fixture(user)

    for left <- 4..0//-1 do
      assert %{"error" => "invalid_code", "attempts_left" => ^left} =
               second_step(challenge, "000000") |> json_response(401)
    end

    assert %{"error" => "not_found"} = second_step(challenge, totp(secret)) |> json_response(404)
  end

  test "5 wrong codes across challenges lock the member's second step for 15 minutes", %{
    user: user,
    secret: secret
  } do
    for _ <- 1..3, do: second_step(challenge_fixture(user), "000000")
    challenge = challenge_fixture(user)
    for _ <- 1..2, do: second_step(challenge, "111111")

    assert %{"error" => "locked"} =
             second_step(challenge_fixture(user), totp(secret)) |> json_response(429)

    Repo.update_all(MlAccounts.Throttle, set: [inserted_at: ago(15, :minute)])
    assert second_step(challenge_fixture(user), totp(secret)) |> json_response(201)
  end

  test "an expired (5 minutes), unknown or missing challenge is not found", %{
    user: user,
    secret: secret
  } do
    challenge = challenge_fixture(user)
    Repo.update_all(LoginChallenge, set: [inserted_at: ago(5, :minute)])
    assert %{"error" => "not_found"} = second_step(challenge, totp(secret)) |> json_response(404)
    assert %{"error" => "not_found"} = second_step("unknown", totp(secret)) |> json_response(404)

    assert %{"error" => "not_found"} =
             build_conn() |> internal() |> post("/api/sessions/2fa", %{}) |> json_response(404)
  end

  test "changing the password kills pending challenges", %{user: user, secret: secret} do
    challenge = challenge_fixture(user)

    {:ok, _} =
      MlAccounts.change_password(
        user,
        %{"current_password" => password(), "password" => "another long passphrase"},
        nil
      )

    assert %{"error" => "not_found"} = second_step(challenge, totp(secret)) |> json_response(404)
  end
end
