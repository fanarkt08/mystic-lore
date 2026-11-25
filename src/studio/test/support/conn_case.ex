defmodule MlStudioWeb.ConnCase do
  @moduledoc "Tests of the HTTP API: requests signed as `web` on behalf of a member (`as_user/2`)."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlStudioWeb.Endpoint
      use Oban.Testing, repo: MlStudio.Repo
      import Plug.Conn
      import Phoenix.ConnTest
      import Ecto.Query
      import MlStudioWeb.ConnCase
      import MlStudio.DataCase, only: [put_studio_env: 2]
      import MlStudio.ServiceStub
      import MlStudio.Fixtures
      alias MlStudio.Repo
    end
  end

  setup tags do
    MlStudio.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def as_user(conn, user_id),
    do:
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        "Bearer " <> MlShared.InternalToken.sign("web", user_id)
      )
end
