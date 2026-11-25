defmodule MlLearningWeb.AdminTest do
  use MlLearningWeb.ConnCase, async: true

  defp stub_role(role) do
    Req.Test.stub(MlShared.Client, fn conn ->
      case role do
        :down -> Req.Test.transport_error(conn, :econnrefused)
        role -> Req.Test.json(conn, %{"user" => %{"id" => "x", "role" => role}})
      end
    end)
  end

  defp stats(user_id),
    do: build_conn() |> as_user(user_id) |> get("/api/admin/stats")

  test "staff only (role read from accounts on every call); real counts" do
    stub_role("user")
    assert %{"error" => "forbidden"} = stats(Ecto.UUID.generate()) |> json_response(403)

    stub_role("moderator")

    assert %{"stats" => %{"enrollments" => e, "lessons_completed_7d" => l, "xp_7d" => xp}} =
             stats(Ecto.UUID.generate()) |> json_response(200)

    assert Enum.all?([e, l, xp], &is_integer/1)

    stub_role(:down)
    assert %{"error" => "roles_unavailable"} = stats(Ecto.UUID.generate()) |> json_response(503)
  end
end
