defmodule MysticWeb.OfflineHTML do
  @moduledoc """
  The offline page: a standalone document, without LiveView, CSRF token or member data.
  """
  use MysticWeb, :html

  embed_templates "offline_html/*"
end
