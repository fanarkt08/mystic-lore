defmodule MlAccountsWeb.ConnCase do
  @moduledoc "Tests HTTP : bac à sable SQL, appels signés comme ceux de `web`, fixtures."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlAccountsWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import MlAccountsWeb.ConnCase
      import MlAccounts.Fixtures
      alias MlAccounts.Repo
    end
  end

  setup tags do
    MlAccounts.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Ajoute le jeton interne d'un appel venant de `web`, au nom de `user_id` si fourni."
  def internal(conn, user_id \\ nil) do
    Plug.Conn.put_req_header(
      conn,
      "authorization",
      "Bearer " <> MlShared.InternalToken.sign("web", user_id)
    )
  end

  def with_session(conn, token), do: Plug.Conn.put_req_header(conn, "x-session-token", token)
end
