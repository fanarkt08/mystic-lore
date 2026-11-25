defmodule MysticWeb.Routes.Pages do
  @moduledoc """
  Pages juridiques provisoires, aide (`/help`, recherche côté serveur), contact (`/contact`) et accueil guidé
  (`/welcome`), insérées dans `MysticWeb.Router`. La file du support du staff est dans `MysticWeb.Routes.Admin`.
  """
  defmacro browser, do: quote(do: nil)

  defmacro public do
    quote do
      live "/legal", LegalLive, :index
      live "/legal/:document", LegalLive, :show
      live "/help", HelpLive
      live "/contact", ContactLive
    end
  end

  defmacro member do
    quote do
      live "/welcome", WelcomeLive
    end
  end
end
