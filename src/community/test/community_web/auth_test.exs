defmodule MlCommunityWeb.AuthTest do
  use MlCommunityWeb.ConnCase, async: true

  @salt "ml-internal-v1"

  test "GET /healthz answers without a token", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get("/healthz") |> json_response(200)
  end

  test "every /api route needs a valid internal token; member routes need a user" do
    id = uuid()

    public = [{:get, "/api/categories"}, {:get, "/api/discussions"}, {:get, "/api/discussions/x"}]

    member = [
      {:post, "/api/discussions"},
      {:patch, "/api/discussions/x"},
      {:delete, "/api/discussions/x"},
      {:put, "/api/discussions/x/follow"},
      {:delete, "/api/discussions/x/follow"},
      {:put, "/api/discussions/x/vote"},
      {:delete, "/api/discussions/x/vote"},
      {:put, "/api/discussions/x/solution"},
      {:delete, "/api/discussions/x/solution"},
      {:post, "/api/discussions/x/replies"},
      {:patch, "/api/replies/#{id}"},
      {:delete, "/api/replies/#{id}"},
      {:put, "/api/replies/#{id}/vote"},
      {:delete, "/api/replies/#{id}/vote"},
      {:post, "/api/reports"},
      {:post, "/api/moderation/discussions/#{id}"},
      {:post, "/api/moderation/replies/#{id}"},
      {:get, "/api/moderation/reports"},
      {:post, "/api/moderation/reports/#{id}/resolve"}
    ]

    bad = [
      nil,
      "Bearer garbage",
      # utilisateur qui n'est pas un UUID
      "Bearer " <> MlShared.InternalToken.sign("web", "lea"),
      # signé avec un autre secret
      "Bearer " <>
        Plug.Crypto.sign(String.duplicate("x", 64), @salt, %{"svc" => "web", "sub" => id})
    ]

    # jeton de service valide mais sans utilisateur : refusé sur les routes de membre seulement
    service_only = "Bearer " <> MlShared.InternalToken.sign("web")

    for {method, path} <- public ++ member,
        header <- bad ++ if({method, path} in member, do: [service_only], else: []) do
      conn =
        if header, do: put_req_header(build_conn(), "authorization", header), else: build_conn()

      assert %{"error" => "unauthorized"} =
               conn |> dispatch(@endpoint, method, path) |> json_response(401),
             "#{method} #{path} accepted with #{inspect(header)}"
    end

    for {method, path} <- public do
      conn = put_req_header(build_conn(), "authorization", service_only)
      refute dispatch(conn, @endpoint, method, path).status == 401
    end
  end

  test "identity comes from the token, never from the body" do
    {author, intruder} = {uuid(), uuid()}
    d = discussion!(author)

    assert %{"error" => "forbidden"} =
             api(:patch, "/api/discussions/#{d.slug}", intruder, %{
               "title" => "Taken over by someone",
               "author_id" => author,
               "user_id" => author
             })
             |> json_response(403)

    %{"discussion" => created} =
      api(:post, "/api/discussions", intruder, %{
        "category" => "off-topic",
        "title" => "Who wrote this?",
        "body" => "The token decides, not the body.",
        "author_id" => author,
        "slug" => "chosen-slug",
        "helpful_count" => 99,
        "pinned" => true
      })
      |> json_response(201)

    assert %{"author" => %{"id" => ^intruder}, "helpful_count" => 0, "pinned" => false} = created
    refute created["slug"] == "chosen-slug"
  end
end
