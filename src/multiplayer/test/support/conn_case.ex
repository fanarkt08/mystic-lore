defmodule MlMultiplayerWeb.ConnCase do
  @moduledoc """
  Tests HTTP : sandbox SQL, faux services (`MlMultiplayer.Fixtures.stub_services/1`) et requêtes signées
  comme le ferait `web` (`api/4`, jeton interne `MlShared.InternalToken.sign("web", user_id)`).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlMultiplayerWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Ecto.Query
      import MlMultiplayer.Fixtures
      import MlMultiplayerWeb.ConnCase
      alias MlMultiplayer.Repo
    end
  end

  setup tags do
    MlMultiplayer.DataCase.setup_sandbox(tags)
    MlMultiplayer.Fixtures.stub_services()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def as_user(conn, user_id) do
    Plug.Conn.put_req_header(
      conn,
      "authorization",
      "Bearer " <> MlShared.InternalToken.sign("web", user_id)
    )
  end

  @doc "Requête JSON signée pour `user_id`, comme `MlShared.Client` depuis `web`."
  def api(method, path, user_id, body \\ nil) do
    conn = Phoenix.ConnTest.build_conn() |> as_user(user_id)

    if body do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(MlMultiplayerWeb.Endpoint, method, path, Jason.encode!(body))
    else
      Phoenix.ConnTest.dispatch(conn, MlMultiplayerWeb.Endpoint, method, path)
    end
  end
end
