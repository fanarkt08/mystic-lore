defmodule MysticWeb.Routes.Studio do
  @moduledoc "Routes du studio, insérées dans `MysticWeb.Router`."
  defmacro browser do
    quote do
      get "/studio/:id/images/:image_id", Studio.ImageController, :show
      get "/studio/:id/media/:media_id", Studio.MediaController, :show
      get "/media/studio/:media_id", Studio.MediaController, :published
    end
  end

  defmacro public, do: quote(do: nil)

  defmacro member do
    quote do
      live "/studio", Studio.IndexLive
      live "/studio/new", Studio.NewLive
      live "/studio/credits", Studio.CreditsLive
      live "/studio/review", Studio.ReviewLive, :index
      live "/studio/review/:id", Studio.ReviewLive, :show
      live "/studio/:id", Studio.ProjectLive
    end
  end
end
