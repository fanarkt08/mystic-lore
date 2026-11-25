defmodule MlSharedTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias MlShared.{InternalToken, Client, Events}

  test "internal token round trip and tampering" do
    t = InternalToken.sign("web", "u1")
    assert {:ok, %{"svc" => "web", "sub" => "u1"}} = InternalToken.verify(t)
    assert {:error, :invalid} = InternalToken.verify(t <> "x")
    assert {:error, :invalid} = InternalToken.verify(nil)
  end

  test "secret: empty or short values are rejected" do
    original = Application.get_env(:ml_shared, :internal_secret)

    try do
      for bad <- ["", "short-secret"] do
        Application.put_env(:ml_shared, :internal_secret, bad)
        assert_raise RuntimeError, ~r/INTERNAL_SECRET/, fn -> InternalToken.secret() end
      end
    after
      Application.put_env(:ml_shared, :internal_secret, original)
    end
  end

  test "plug requires a valid token, and a user when asked" do
    conn = conn(:get, "/") |> MlShared.Plug.Internal.call(:optional)
    assert conn.status == 401

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> InternalToken.sign("web"))
      |> MlShared.Plug.Internal.call(:required)

    assert conn.status == 401

    conn =
      conn(:get, "/")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> InternalToken.sign("web", "u9"))
      |> MlShared.Plug.Internal.call(:required)

    refute conn.halted
    assert conn.assigns.user_id == "u9"
  end

  test "client normalizes responses and signs requests" do
    Application.put_env(:ml_shared, :req_options, plug: {Req.Test, __MODULE__}, retry: false)

    Req.Test.stub(__MODULE__, fn conn ->
      ["Bearer " <> t] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, %{"sub" => sub}} = InternalToken.verify(t)

      case conn.request_path do
        "/ok" ->
          Req.Test.json(conn, %{"sub" => sub})

        "/missing" ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})
      end
    end)

    assert {:ok, %{"sub" => "u1"}} = Client.get(:learning, "/ok", as: "u1")
    # des en-têtes supplémentaires ne doivent pas écraser le jeton interne
    assert {:ok, %{"sub" => "u2"}} =
             Client.get(:learning, "/ok", as: "u2", headers: [{"x-session-token", "abc"}])

    assert {:error, {:http, 404, %{"error" => "not_found"}}} = Client.get(:learning, "/missing")
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, :unavailable} = Client.get(:learning, "/x")

    # avec relances activées, un service injoignable répond vite (pas de backoff de plusieurs secondes)
    Application.put_env(:ml_shared, :req_options, plug: {Req.Test, __MODULE__})
    {us, {:error, :unavailable}} = :timer.tc(fn -> Client.get(:learning, "/x") end)
    assert us < 1_500_000
  after
    Application.delete_env(:ml_shared, :req_options)
  end

  test "events pubsub" do
    Events.subscribe("user:x")
    Events.broadcast("user:x", {:unread_changed, "x"})
    assert_receive {:unread_changed, "x"}
  end
end
