defmodule MysticWeb do
  @moduledoc """
  Entrypoint for the browser-facing interface (`use MysticWeb, :live_view`, `:controller`, `:html`...).
  """

  # fonts : polices auto-hébergées (licences OFL comprises) ; icons : icônes de l'application installable,
  # générées par e2e/tools/make_icons.mjs
  def static_paths, do: ~w(assets fonts images icons favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      use Gettext, backend: MysticWeb.Gettext
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      alias MysticWeb.Api
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: MysticWeb.Gettext
      import Phoenix.HTML
      import MysticWeb.CoreComponents
      import MysticWeb.MysticComponents
      # états thématiques d'un lien expiré ou d'un accès terminé
      import MysticWeb.AccessComponents
      import MysticWeb.Format
      alias Phoenix.LiveView.JS
      alias MysticWeb.Layouts
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MysticWeb.Endpoint,
        router: MysticWeb.Router,
        statics: MysticWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
