defmodule MlAccountsWeb.TwoFactorController do
  @moduledoc "2FA TOTP du membre connecté (`MlAccounts.TwoFactor`)."
  use MlAccountsWeb, :controller
  alias MlAccounts.TwoFactor

  def show(conn, _params), do: json(conn, TwoFactor.status(conn.assigns.current_user))

  def setup(conn, params) do
    with {:ok, setup} <- TwoFactor.setup(conn.assigns.current_user, params["password"]),
         do: json(conn, setup)
  end

  def enable(conn, params) do
    with {:ok, codes} <- TwoFactor.enable(conn.assigns.current_user, params["code"]),
         do: json(conn, %{recovery_codes: codes})
  end

  def disable(conn, params) do
    with :ok <- TwoFactor.disable(conn.assigns.current_user, params["password"], params["code"]),
         do: send_resp(conn, 204, "")
  end

  def recovery_codes(conn, params) do
    with {:ok, codes} <-
           TwoFactor.regenerate_recovery_codes(conn.assigns.current_user, params["password"]),
         do: json(conn, %{recovery_codes: codes})
  end
end
