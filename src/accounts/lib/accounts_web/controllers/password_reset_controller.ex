defmodule MlAccountsWeb.PasswordResetController do
  @moduledoc "Mot de passe oublié : demande (toujours 204, pas d'énumération), vérification du lien, nouveau mot de passe."
  use MlAccountsWeb, :controller

  def create(conn, params) do
    :ok = MlAccounts.request_password_reset(params["email"])
    send_resp(conn, 204, "")
  end

  def show(conn, %{"token" => token}) do
    if MlAccounts.password_reset_valid?(token),
      do: send_resp(conn, 204, ""),
      else: {:error, :not_found}
  end

  def update(conn, %{"token" => token} = params) do
    with {:ok, _user} <- MlAccounts.reset_password(token, Map.take(params, ["password"])),
         do: send_resp(conn, 204, "")
  end
end
