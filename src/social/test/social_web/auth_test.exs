defmodule MlSocialWeb.AuthTest do
  use MlSocialWeb.ConnCase, async: true

  @salt "ml-internal-v1"

  test "GET /healthz répond sans jeton", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/healthz") |> json_response(200)
  end

  test "toute route /api exige un jeton interne valide portant un utilisateur" do
    id = uuid()

    routes = [
      {:get, "/api/me/friends"},
      {:get, "/api/me/friend-requests"},
      {:post, "/api/friend-requests"},
      {:post, "/api/friend-requests/#{id}/accept"},
      {:post, "/api/friend-requests/#{id}/decline"},
      {:delete, "/api/friends/#{id}"},
      {:get, "/api/me/blocks"},
      {:post, "/api/blocks"},
      {:delete, "/api/blocks/#{id}"},
      {:get, "/api/me/conversations"},
      {:post, "/api/conversations"},
      {:get, "/api/conversations/#{id}"},
      {:get, "/api/conversations/#{id}/messages"},
      {:post, "/api/conversations/#{id}/messages"},
      {:post, "/api/conversations/#{id}/read"},
      {:put, "/api/conversations/#{id}/mute"},
      {:delete, "/api/conversations/#{id}/mute"},
      {:get, "/api/me/unread"},
      {:get, "/api/attachments/#{id}"},
      {:post, "/api/groups"},
      {:patch, "/api/conversations/#{id}"},
      {:post, "/api/conversations/#{id}/members"},
      {:delete, "/api/conversations/#{id}/members/#{id}"},
      {:post, "/api/conversations/#{id}/leave"},
      {:get, "/api/me/settings"},
      {:patch, "/api/me/settings"},
      {:post, "/api/reports"},
      {:post, "/api/moderation/reports/#{id}/attachment"}
    ]

    headers = [
      nil,
      "Bearer garbage",
      # jeton de service sans utilisateur
      "Bearer " <> MlShared.InternalToken.sign("web"),
      # utilisateur qui n'est pas un UUID
      "Bearer " <> MlShared.InternalToken.sign("web", "lea"),
      # signé avec un autre secret
      "Bearer " <>
        Plug.Crypto.sign(String.duplicate("x", 64), @salt, %{"svc" => "web", "sub" => id})
    ]

    for {method, path} <- routes, header <- headers do
      conn =
        if header, do: put_req_header(build_conn(), "authorization", header), else: build_conn()

      assert %{"error" => "unauthorized"} =
               conn |> dispatch(@endpoint, method, path) |> json_response(401),
             "#{method} #{path} accepté avec #{inspect(header)}"
    end
  end

  test "l'identité vient du jeton, jamais du corps de la requête" do
    {a, b, c} = {uuid(), uuid(), uuid()}
    %{"id" => id} = api(:post, "/api/friend-requests", a, %{user_id: b}) |> json_response(201)

    # c ne peut pas accepter « en tant que » b en le déclarant dans le corps
    assert api(:post, "/api/friend-requests/#{id}/accept", c, %{user_id: b, addressee_id: b})
           |> json_response(404)

    refute MlSocial.Friends.friends?(a, b)
  end
end
