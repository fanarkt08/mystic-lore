defmodule MysticWeb.Routes.Privacy do
  @moduledoc """
  Téléchargement d'un export de données (`/settings/exports/:id/download`, proxy JSON vers accounts).
  La section « Your data » et la bannière de suppression vivent dans `/settings` et `/dashboard`.
  """
  defmacro browser do
    quote do
      get "/settings/exports/:id/download", Privacy.ExportController, :show
    end
  end
end
