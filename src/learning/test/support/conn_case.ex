defmodule MlLearningWeb.ConnCase do
  @moduledoc "Tests HTTP : requêtes signées comme le ferait le service web (`as_user/2`, `as_service/1`)."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlLearningWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import MlLearningWeb.ConnCase
      import MlLearning.Fixtures
    end
  end

  setup tags do
    MlLearning.DataCase.setup_sandbox(tags)
    MlLearning.Fixtures.stub_center()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def as_user(conn, user_id),
    do:
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        "Bearer " <> MlShared.InternalToken.sign("web", user_id)
      )

  def as_service(conn), do: as_user(conn, nil)
end
