defmodule MlAccountsWeb do
  @moduledoc "API HTTP JSON interne du service accounts : `use MlAccountsWeb, :router` ou `:controller`."

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
      action_fallback MlAccountsWeb.FallbackController
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
