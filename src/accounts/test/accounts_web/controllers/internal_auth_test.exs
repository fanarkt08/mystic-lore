defmodule MlAccountsWeb.InternalAuthTest do
  use MlAccountsWeb.ConnCase, async: true

  @routes [
    post: "/api/users",
    get: "/api/users",
    post: "/api/users/confirm",
    post: "/api/users/resend-confirmation",
    get: "/api/users/by-username/someone",
    post: "/api/sessions",
    get: "/api/sessions/current",
    delete: "/api/sessions/current",
    get: "/api/users/search",
    patch: "/api/me",
    put: "/api/me/password",
    post: "/api/sessions/2fa",
    post: "/api/password-resets",
    get: "/api/password-resets/some-token",
    post: "/api/password-resets/some-token",
    post: "/api/me/email",
    post: "/api/me/email/confirm",
    get: "/api/me/sessions",
    delete: "/api/me/sessions",
    delete: "/api/me/sessions/#{Ecto.UUID.generate()}",
    get: "/api/me/2fa",
    post: "/api/me/2fa/setup",
    post: "/api/me/2fa/enable",
    post: "/api/me/2fa/disable",
    post: "/api/me/2fa/recovery-codes"
  ]

  test "every /api route requires a valid internal token" do
    tampered = "Bearer " <> MlShared.InternalToken.sign("web", Ecto.UUID.generate()) <> "x"

    for {method, path} <- @routes, authorization <- [nil, "Bearer forged", tampered] do
      conn =
        if authorization,
          do: put_req_header(build_conn(), "authorization", authorization),
          else: build_conn()

      assert %{"error" => "unauthorized"} =
               conn |> dispatch(@endpoint, method, path, %{}) |> json_response(401)
    end
  end

  test "GET /healthz needs no token and checks the database" do
    assert build_conn() |> get("/healthz") |> json_response(200) == %{"status" => "ok"}
  end
end
