defmodule MlAccountsWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  test "renders framework errors in the contract format" do
    assert MlAccountsWeb.ErrorJSON.render("404.json", %{}) == %{error: "not_found"}
    assert MlAccountsWeb.ErrorJSON.render("500.json", %{}) == %{error: "internal_server_error"}
  end
end
