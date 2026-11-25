defmodule MlCommunityWeb.ConnCase do
  @moduledoc """
  Tests HTTP : sandbox SQL, requêtes signées comme le ferait `web` (`api/4`) et faux accounts / social
  (`MlCommunity.Fixtures.stub_services/1`, installé par défaut ; chaque test peut le remplacer).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlCommunityWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import MlCommunity.Fixtures
      import MlCommunityWeb.ConnCase
    end
  end

  setup tags do
    MlCommunity.DataCase.setup_sandbox(tags)
    MlCommunity.Fixtures.stub_services()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Requête JSON signée pour `user_id` (`nil` : visiteur), comme `MlShared.Client` depuis `web`."
  def api(method, path, user_id, body \\ nil) do
    conn =
      Plug.Conn.put_req_header(
        Phoenix.ConnTest.build_conn(),
        "authorization",
        "Bearer " <> MlShared.InternalToken.sign("web", user_id)
      )

    if body do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(MlCommunityWeb.Endpoint, method, path, Jason.encode!(body))
    else
      Phoenix.ConnTest.dispatch(conn, MlCommunityWeb.Endpoint, method, path)
    end
  end
end
