defmodule MlLearningWeb.InternalXpTest do
  use MlLearningWeb.ConnCase, async: true
  alias MlLearning.Progress

  defp post_xp(conn, caller, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign(caller))
    |> post("/api/internal/xp", body)
  end

  test "awards XP once per ref_key, in the caller's namespace", %{conn: conn} do
    uid = Ecto.UUID.generate()
    body = %{"user_id" => uid, "ref_key" => "multiplayer:match:1", "amount" => 50}
    assert %{"xp" => "awarded"} = conn |> post_xp("multiplayer", body) |> json_response(200)

    assert %{"xp" => "duplicate"} =
             build_conn() |> post_xp("multiplayer", body) |> json_response(200)

    assert %{xp: 50} = Progress.dashboard(uid)
  end

  test "refuses another namespace, bad amounts and missing token", %{conn: conn} do
    uid = Ecto.UUID.generate()

    assert conn
           |> post_xp("multiplayer", %{"user_id" => uid, "ref_key" => "lesson:x", "amount" => 5})
           |> json_response(422)

    assert build_conn()
           |> post_xp("multiplayer", %{
             "user_id" => uid,
             "ref_key" => "multiplayer:",
             "amount" => 5
           })
           |> json_response(422)

    assert build_conn()
           |> post_xp("multiplayer", %{
             "user_id" => uid,
             "ref_key" => "multiplayer:a",
             "amount" => 0
           })
           |> json_response(422)

    assert build_conn()
           |> post_xp("multiplayer", %{
             "user_id" => "nope",
             "ref_key" => "multiplayer:a",
             "amount" => 5
           })
           |> json_response(422)

    assert build_conn() |> post("/api/internal/xp", %{}) |> json_response(401)
  end
end
