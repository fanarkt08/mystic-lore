defmodule MlMultiplayerWeb do
  @moduledoc "API JSON interne du service multiplayer (appelée par `web` avec un jeton interne, jamais par le navigateur)."

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
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
