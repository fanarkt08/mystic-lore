defmodule MlLearningWeb.DashboardPreferencesTest do
  @moduledoc "Recommandations ordonnées par les centres d'intérêt du membre (préférences d'accounts)."
  use MlLearningWeb.ConnCase, async: true

  defp dashboard(conn, user, params),
    do: conn |> as_user(user) |> get("/api/me/dashboard", params) |> json_response(200)

  test "interests order the recommendations by category, then free first, then title", %{
    conn: conn
  } do
    user = Ecto.UUID.generate()
    adventure_fixture(%{title: "B code", category: "coding"})
    adventure_fixture(%{title: "A code", category: "coding", premium: true})
    adventure_fixture(%{title: "Star map", category: "science"})
    adventure_fixture(%{title: "Old tales", category: "humanities"})

    titles = fn params ->
      conn |> dashboard(user, params) |> Map.fetch!("recommendations") |> Enum.map(& &1["title"])
    end

    assert titles.(%{"categories" => "science,humanities"}) == ["Star map", "Old tales", "B code"]
    assert titles.(%{"categories" => "humanities"}) == ["Old tales", "B code", "Star map"]
    # sans préférence (ou catégories inconnues) : ordre habituel, gratuites d'abord
    assert titles.(%{"categories" => "cooking,"}) == titles.(%{})
    assert titles.(%{}) == ["B code", "Old tales", "Star map"]
  end
end
