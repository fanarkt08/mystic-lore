defmodule MysticWeb.NotFoundError do
  @moduledoc "Raised by LiveViews when a service answers 404: rendered as the themed 404 page."
  defexception message: "not found", plug_status: 404
end
