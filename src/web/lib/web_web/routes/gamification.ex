defmodule MysticWeb.Routes.Gamification do
  @moduledoc """
  Routes des badges, insérées dans `MysticWeb.Router` : `/achievements` (`member/0`).
  """
  defmacro browser, do: quote(do: nil)
  defmacro public, do: quote(do: nil)

  defmacro member do
    quote do
      live "/achievements", Gamification.AchievementsLive
    end
  end
end
