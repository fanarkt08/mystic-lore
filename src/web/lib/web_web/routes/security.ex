defmodule MysticWeb.Routes.Security do
  @moduledoc """
  Routes de sécurité du compte, insérées dans `MysticWeb.Router` : second facteur de connexion et mot de passe
  oublié (`browser/0`), confirmation de la nouvelle adresse (`member/0`).
  """
  defmacro browser do
    quote do
      get "/login/2fa", SessionController, :two_factor
      post "/login/2fa", SessionController, :create_two_factor
      get "/forgot-password", Security.PasswordResetController, :new
      post "/forgot-password", Security.PasswordResetController, :create
      get "/reset-password/:token", Security.PasswordResetController, :edit
      post "/reset-password/:token", Security.PasswordResetController, :update
    end
  end

  defmacro public, do: quote(do: nil)

  defmacro member do
    quote do
      live "/settings/confirm-email/:token", Security.ConfirmEmailLive
    end
  end
end
