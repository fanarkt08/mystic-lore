defmodule MlAccounts.TwoFactorKeyTest do
  # async: false : le test modifie la clé de chiffrement, une configuration globale
  use MlAccounts.DataCase, async: false
  alias MlAccounts.TwoFactor

  test "with another encryption key, TOTP secrets are unreadable but recovery codes still work" do
    {user, secret, [code | _]} = two_factor_fixture(user_fixture())
    Application.put_env(:accounts, :totp_encryption_key, String.duplicate("k", 32))
    on_exit(fn -> Application.delete_env(:accounts, :totp_encryption_key) end)

    assert {:error, :invalid_code} = TwoFactor.verify(user, totp(secret))
    assert :ok = TwoFactor.verify(user, code)
  end

  test "a dedicated key shorter than 32 bytes is refused" do
    user = user_fixture()
    Application.put_env(:accounts, :totp_encryption_key, "too-short")
    on_exit(fn -> Application.delete_env(:accounts, :totp_encryption_key) end)

    assert_raise RuntimeError, ~r/TOTP_ENCRYPTION_KEY/, fn ->
      TwoFactor.setup(user, password())
    end
  end
end
