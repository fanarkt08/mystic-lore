defmodule MlSocialWeb.InternalControllerTest do
  use MlSocialWeb.ConnCase, async: true
  alias MlSocial.Friends

  defp service_get(path) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign("multiplayer"))
    |> get(path)
  end

  test "relationship reports friendship and blocks in both directions" do
    [a, b, c] = for _ <- 1..3, do: Ecto.UUID.generate()
    {:ok, req} = Friends.send_request(a, b)
    {:ok, _} = Friends.accept(b, req.id)

    assert %{"friends" => true, "blocked" => false} =
             service_get("/api/internal/relationship?a=#{a}&b=#{b}") |> json_response(200)

    assert %{"friends" => false, "blocked" => false} =
             service_get("/api/internal/relationship?a=#{a}&b=#{c}") |> json_response(200)

    :ok = Friends.block(c, a) |> then(fn _ -> :ok end)

    assert %{"blocked" => true} =
             service_get("/api/internal/relationship?a=#{a}&b=#{c}") |> json_response(200)

    assert %{"user_ids" => [^c]} = service_get("/api/internal/blocks/#{a}") |> json_response(200)
    assert %{"user_ids" => [^a]} = service_get("/api/internal/blocks/#{c}") |> json_response(200)
    assert service_get("/api/internal/relationship?a=nope&b=#{c}") |> json_response(422)
  end

  test "requires the internal token" do
    assert build_conn()
           |> get("/api/internal/blocks/#{Ecto.UUID.generate()}")
           |> json_response(401)
  end
end
