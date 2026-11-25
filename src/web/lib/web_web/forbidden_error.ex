defmodule MysticWeb.ForbiddenError do
  @moduledoc "Raised when a signed-in member opens a staff page without the role: rendered as the themed 403 page."
  defexception message: "forbidden", plug_status: 403
end
