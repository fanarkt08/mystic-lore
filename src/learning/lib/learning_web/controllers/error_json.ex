defmodule MlLearningWeb.ErrorJSON do
  @moduledoc "Erreurs non gérées (route inconnue, JSON invalide, exception) au format du contrat : `{\"error\": \"not_found\"}`."

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    %{error: message |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")}
  end
end
