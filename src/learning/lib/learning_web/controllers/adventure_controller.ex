defmodule MlLearningWeb.AdventureController do
  use MlLearningWeb, :controller
  alias MlLearning.{Catalog, Entitlements, Progress}

  action_fallback MlLearningWeb.FallbackController

  def index(conn, params), do: render(conn, :index, page: Catalog.list_adventures(params))

  def show(conn, %{"slug" => slug}) do
    user_id = conn.assigns.user_id

    with {:ok, adventure} <- Catalog.fetch_adventure(slug) do
      render(conn, :show,
        adventure: adventure,
        access: access(adventure, user_id),
        state: Progress.state(user_id, adventure)
      )
    end
  end

  def enroll(conn, %{"slug" => slug}) do
    user_id = conn.assigns.user_id

    with {:ok, adventure} <- Catalog.fetch_adventure(slug),
         :ok <- Entitlements.check(adventure, user_id) do
      :ok = Progress.enroll(user_id, adventure)
      json(conn, %{enrolled: true})
    end
  end

  # Le détail reste visible ; droits illisibles (billing injoignable) → "premium_required", jamais "open".
  defp access(_adventure, nil), do: "login_required"

  defp access(adventure, user_id),
    do: if(Entitlements.check(adventure, user_id) == :ok, do: "open", else: "premium_required")
end
