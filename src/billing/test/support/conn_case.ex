defmodule MlBillingWeb.ConnCase do
  @moduledoc "Tests of the HTTP API (SQL sandbox, helpers of `MlBilling.TestHelpers`)."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlBillingWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Ecto.Query
      import MlBillingWeb.ConnCase
      import MlBilling.TestHelpers
      alias MlBilling.Repo
    end
  end

  setup tags do
    MlBilling.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Request signed with an internal token as `web`, on behalf of `user_id` (nil: service only)."
  def as_user(conn, user_id),
    do:
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        "Bearer " <> MlShared.InternalToken.sign("web", user_id)
      )
end
