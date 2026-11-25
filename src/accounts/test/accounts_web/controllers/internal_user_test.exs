defmodule MlAccountsWeb.InternalUserTest do
  use MlAccountsWeb.ConnCase, async: true
  import MlAccounts.Fixtures

  test "returns role and state without the email; 404 for unknown ids; token required", %{
    conn: conn
  } do
    user = user_fixture()
    body = conn |> internal() |> get("/api/internal/users/#{user.id}") |> json_response(200)
    assert %{"user" => %{"id" => id, "role" => "user", "confirmed" => _}} = body
    assert id == user.id
    refute Map.has_key?(body["user"], "email")

    assert build_conn()
           |> internal()
           |> get("/api/internal/users/#{Ecto.UUID.generate()}")
           |> json_response(404)

    assert build_conn()
           |> internal()
           |> get("/api/internal/users/not-a-uuid")
           |> json_response(404)

    assert build_conn() |> get("/api/internal/users/#{user.id}") |> json_response(401)
  end
end
