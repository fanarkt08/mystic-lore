defmodule MlMultiplayerWeb.AdminTest do
  @moduledoc "Restriction du chat par le staff (accounts) et indicateurs du staff."
  use MlMultiplayerWeb.ConnCase, async: true

  setup do
    host = uuid()
    lobby = lobby!(host)
    %{host: host, lobby: lobby, guest: join!(lobby, uuid())}
  end

  @tag :capture_log
  test "a restricted member can't write in a lobby chat; accounts down → refused", ctx do
    until = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
    iso = DateTime.to_iso8601(until)
    stub_services(restricted: %{ctx.guest => iso})
    path = "/api/lobbies/#{ctx.lobby.id}/messages"

    assert %{"error" => "restricted", "restricted_until" => ^iso} =
             api(:post, path, ctx.guest, %{body: "hello"}) |> json_response(403)

    # reading the chat stays possible
    assert %{"entries" => []} = api(:get, path, ctx.guest) |> json_response(200)

    assert %{"message" => _} =
             api(:post, path, ctx.host, %{body: "welcome"}) |> json_response(201)

    third = join!(ctx.lobby, uuid())
    stub_services(accounts: :down)

    assert %{"error" => "accounts_unavailable"} =
             api(:post, path, third, %{body: "hi"}) |> json_response(503)
  end

  test "stats: staff only, real counts", ctx do
    staff = uuid()
    stub_services(staff: [staff])

    assert %{"error" => "forbidden"} =
             api(:get, "/api/admin/stats", ctx.host) |> json_response(403)

    assert %{"stats" => %{"open_lobbies" => 1, "matches_7d" => 0}} =
             api(:get, "/api/admin/stats", staff) |> json_response(200)
  end
end
