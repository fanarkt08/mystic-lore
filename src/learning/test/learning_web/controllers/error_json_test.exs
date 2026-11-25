defmodule MlLearningWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  test "renders the contract's error codes" do
    assert MlLearningWeb.ErrorJSON.render("404.json", %{}) == %{error: "not_found"}
    assert MlLearningWeb.ErrorJSON.render("500.json", %{}) == %{error: "internal_server_error"}
    assert MlLearningWeb.ErrorJSON.render("400.json", %{}) == %{error: "bad_request"}
  end
end
