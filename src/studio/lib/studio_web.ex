defmodule MlStudioWeb do
  @moduledoc "Web layer (internal JSON API): `use MlStudioWeb, :router | :controller`."

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
      alias MlStudio.View
      action_fallback MlStudioWeb.FallbackController
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
