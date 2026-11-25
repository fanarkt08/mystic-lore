defmodule MlAccountsWeb.ErrorJSON do
  @moduledoc "Erreurs rendues par Phoenix (route inconnue, exception) au format du contrat : `{\"error\": \"not_found\"}`."

  def render(template, _assigns) do
    code =
      template
      |> Phoenix.Controller.status_message_from_template()
      |> String.downcase()
      |> String.replace(" ", "_")

    %{error: code}
  end
end
