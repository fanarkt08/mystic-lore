defmodule MysticWeb.Routes.Community do
  @moduledoc """
  Routes du forum, insérées dans `MysticWeb.Router` : liste et discussion (`public/0`), création et édition
  (`member/0`).
  """
  defmacro browser, do: quote(do: nil)

  defmacro public do
    quote do
      live "/community", Community.IndexLive
      live "/community/discussions/:slug", Community.ShowLive
    end
  end

  defmacro member do
    quote do
      live "/community/new", Community.FormLive, :new
      live "/community/discussions/:slug/edit", Community.FormLive, :edit
    end
  end
end
