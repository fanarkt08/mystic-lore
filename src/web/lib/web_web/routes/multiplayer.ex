defmodule MysticWeb.Routes.Multiplayer do
  @moduledoc """
  Routes du multijoueur, insérées dans `MysticWeb.Router` : activités, salon et partie, lien d'invitation
  (`/multiplayer`, `/multiplayer/lobbies/:id`, `/multiplayer/join/:token`).
  """
  defmacro browser, do: quote(do: nil)
  defmacro public, do: quote(do: nil)

  defmacro member do
    quote do
      live "/multiplayer", Multiplayer.IndexLive
      live "/multiplayer/lobbies/:id", Multiplayer.LobbyLive
      live "/multiplayer/join/:token", Multiplayer.JoinLive
    end
  end
end
