defmodule MlAccountsWeb.TwoFactorTest do
  use MlAccountsWeb.ConnCase, async: true
  alias MlAccounts.{RecoveryCode, Throttle, TwoFactor, User}

  defp call(user, method, path, params \\ %{}),
    do: build_conn() |> internal(user.id) |> dispatch(@endpoint, method, path, params)

  defp status(user), do: call(user, :get, "/api/me/2fa") |> json_response(200)
  defp ago(amount, unit), do: DateTime.add(DateTime.utc_now(:second), -amount, unit)

  defp set_up(user) do
    body = call(user, :post, "/api/me/2fa/setup", %{password: password()}) |> json_response(200)
    {body, Base.decode32!(body["secret"], padding: false)}
  end

  describe "setup and enable" do
    test "the setup needs the password and returns a pending secret, its URI and a QR code" do
      user = user_fixture()

      assert %{"error" => "invalid_credentials"} =
               call(user, :post, "/api/me/2fa/setup", %{password: "not my password"})
               |> json_response(401)

      {body, secret} = set_up(user)
      assert byte_size(secret) == 20

      assert body["otpauth_uri"] =~
               ~r/^otpauth:\/\/totp\/MysticLore:.+\?secret=#{body["secret"]}&issuer=MysticLore$/

      assert body["qr_svg"] =~ "<svg"

      # pending, and encrypted at rest (never the raw secret)
      stored = Repo.get!(User, user.id)
      assert is_nil(stored.totp_secret) and is_binary(stored.totp_pending_secret)
      refute stored.totp_pending_secret =~ secret

      assert status(user) == %{
               "enabled" => false,
               "enabled_at" => nil,
               "recovery_codes_left" => 0
             }
    end

    test "a valid code enables 2FA and returns 10 recovery codes, stored hashed" do
      user = user_fixture()
      {_body, secret} = set_up(user)

      assert %{"error" => "invalid_code"} =
               call(user, :post, "/api/me/2fa/enable", %{code: "000000"}) |> json_response(401)

      assert %{"recovery_codes" => codes} =
               call(user, :post, "/api/me/2fa/enable", %{code: totp(secret)})
               |> json_response(200)

      assert length(codes) == 10 and length(Enum.uniq(codes)) == 10
      assert Enum.all?(codes, &(&1 =~ ~r/^[0-9a-hjkmnp-tv-z]{4}(-[0-9a-hjkmnp-tv-z]{4}){3}$/))

      hashes = RecoveryCode |> Repo.all() |> Enum.map(& &1.code_hash)
      assert length(hashes) == 10 and Enum.all?(hashes, &(byte_size(&1) == 32))

      assert %{"enabled" => true, "enabled_at" => enabled_at, "recovery_codes_left" => 10} =
               status(user)

      assert {:ok, _, 0} = DateTime.from_iso8601(enabled_at)

      assert %{"error" => "already_enabled"} =
               call(user, :post, "/api/me/2fa/setup", %{password: password()})
               |> json_response(409)
    end

    test "enable needs a pending setup" do
      assert %{"error" => "setup_required"} =
               user_fixture()
               |> call(:post, "/api/me/2fa/enable", %{code: "123456"})
               |> json_response(409)
    end

    test "the code used to enable cannot be replayed at sign-in (same time step)" do
      user = user_fixture()
      {_body, secret} = set_up(user)
      code = totp(secret)
      assert call(user, :post, "/api/me/2fa/enable", %{code: code}) |> json_response(200)

      user = Repo.reload!(user)
      assert {:error, :invalid_code} = TwoFactor.verify(user, code)
    end
  end

  describe "TOTP verification" do
    setup do
      {user, secret, codes} = two_factor_fixture(user_fixture())
      %{user: user, secret: secret, codes: codes}
    end

    test "accepts the current step and ±1 step of clock drift, nothing further", %{
      user: user,
      secret: secret
    } do
      # loin dans le futur : aucun pas déjà consommé par la fixture
      now = System.os_time(:second) + 3_600

      for offset <- [-90, -60, 60, 90] do
        assert {:error, :invalid_code} = TwoFactor.verify(user, totp(secret, now + offset), now)
      end

      Repo.delete_all(Throttle)

      for offset <- [-30, 0, 30] do
        assert :ok = TwoFactor.verify(Repo.reload!(user), totp(secret, now + offset), now)
      end
    end

    test "refuses a replayed code, and any code of an earlier step", %{user: user, secret: secret} do
      now = System.os_time(:second) + 3_600
      assert :ok = TwoFactor.verify(user, totp(secret, now), now)

      assert {:error, :invalid_code} =
               TwoFactor.verify(Repo.reload!(user), totp(secret, now), now)

      assert {:error, :invalid_code} =
               TwoFactor.verify(Repo.reload!(user), totp(secret, now - 30), now)

      assert :ok = TwoFactor.verify(Repo.reload!(user), totp(secret, now + 30), now)
    end

    test "concurrent uses of one code: a single success", %{user: user, secret: secret} do
      code = totp(secret)

      results =
        1..5
        |> Task.async_stream(fn _ -> TwoFactor.verify(user, code) end, max_concurrency: 5)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.frequencies(results) == %{:ok => 1, {:error, :invalid_code} => 4}
    end

    test "5 wrong codes in 15 minutes lock the verification, even with the right code", %{
      user: user,
      secret: secret
    } do
      for _ <- 1..5, do: assert({:error, :invalid_code} = TwoFactor.verify(user, "000000"))
      assert {:error, :locked} = TwoFactor.verify(user, totp(secret))

      Repo.update_all(Throttle, set: [inserted_at: ago(15, :minute)])
      assert :ok = TwoFactor.verify(user, totp(secret))
    end

    test "a success resets the failure counter", %{user: user, secret: secret} do
      for _ <- 1..4, do: TwoFactor.verify(user, "000000")
      assert :ok = TwoFactor.verify(user, totp(secret))
      for _ <- 1..4, do: TwoFactor.verify(user, "000000")

      assert :ok =
               TwoFactor.verify(Repo.reload!(user), totp(secret, System.os_time(:second) + 30))
    end
  end

  describe "recovery codes" do
    setup do
      {user, secret, codes} = two_factor_fixture(user_fixture())
      %{user: user, secret: secret, codes: codes}
    end

    test "each code works once; input is forgiving (case, spaces, dashes)", %{
      user: user,
      codes: [code | _]
    } do
      sloppy = code |> String.upcase() |> String.replace("-", " ")
      assert :ok = TwoFactor.verify(user, sloppy)
      assert {:error, :invalid_code} = TwoFactor.verify(user, code)
      assert %{"recovery_codes_left" => 9} = status(user)
    end

    test "concurrent uses of one code: a single success", %{user: user, codes: [code | _]} do
      results =
        1..5
        |> Task.async_stream(fn _ -> TwoFactor.verify(user, code) end, max_concurrency: 5)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.frequencies(results) == %{:ok => 1, {:error, :invalid_code} => 4}
    end

    test "regenerating needs the password and replaces every code", %{
      user: user,
      codes: [old | _]
    } do
      assert %{"error" => "invalid_credentials"} =
               call(user, :post, "/api/me/2fa/recovery-codes", %{password: "nope nope nope"})
               |> json_response(401)

      assert %{"recovery_codes" => [new | _] = codes} =
               call(user, :post, "/api/me/2fa/recovery-codes", %{password: password()})
               |> json_response(200)

      assert length(codes) == 10
      assert {:error, :invalid_code} = TwoFactor.verify(user, old)
      assert :ok = TwoFactor.verify(user, new)
    end
  end

  describe "disable" do
    setup do
      {user, secret, codes} = two_factor_fixture(user_fixture())
      %{user: user, secret: secret, codes: codes}
    end

    test "needs the password and a code; then sign-in no longer asks for a code", %{
      user: user,
      secret: secret
    } do
      assert %{"error" => "invalid_credentials"} =
               call(user, :post, "/api/me/2fa/disable", %{password: "wrong", code: totp(secret)})
               |> json_response(401)

      assert %{"error" => "invalid_code"} =
               call(user, :post, "/api/me/2fa/disable", %{password: password(), code: "000000"})
               |> json_response(401)

      assert call(user, :post, "/api/me/2fa/disable", %{password: password(), code: totp(secret)})
             |> response(204)

      assert status(user) == %{
               "enabled" => false,
               "enabled_at" => nil,
               "recovery_codes_left" => 0
             }

      assert %User{totp_secret: nil, totp_last_step: nil} = Repo.get!(User, user.id)
      assert {:ok, _token, _user} = MlAccounts.login(user.email, password())
    end

    test "accepts a recovery code (lost device)", %{user: user, codes: [code | _]} do
      assert call(user, :post, "/api/me/2fa/disable", %{password: password(), code: code})
             |> response(204)
    end

    test "disable and regenerate need 2FA to be on" do
      user = user_fixture()

      for path <- ["/api/me/2fa/disable", "/api/me/2fa/recovery-codes"] do
        assert %{"error" => "not_enabled"} =
                 call(user, :post, path, %{password: password(), code: "123456"})
                 |> json_response(409)
      end
    end
  end
end
