defmodule MlNotificationsWeb.ConnCase do
  @moduledoc """
  Tests HTTP : sandbox SQL, requêtes signées comme le ferait `web` (`api/4`) ou un service producteur
  (`service/4`), faux accounts installé par défaut (`MlNotifications.Fixtures.fake_accounts/1`).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlNotificationsWeb.Endpoint
      use Oban.Testing, repo: MlNotifications.Repo

      import Plug.Conn
      import Phoenix.ConnTest
      import Ecto.Query
      import MlNotifications.Fixtures
      import MlNotificationsWeb.ConnCase
      alias MlNotifications.Repo
    end
  end

  setup tags do
    MlNotifications.DataCase.setup_sandbox(tags)
    MlNotifications.Fixtures.fake_accounts()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Requête JSON signée pour le membre `user_id`, comme `MlShared.Client` depuis `web`."
  def api(method, path, user_id, body \\ nil), do: signed(method, path, "web", user_id, body)

  @doc "Requête JSON signée par le service `svc`, sans membre (producteurs, accounts)."
  def service(method, path, svc, body \\ nil), do: signed(method, path, svc, nil, body)

  defp signed(method, path, svc, user_id, body) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header(
        "authorization",
        "Bearer " <> MlShared.InternalToken.sign(svc, user_id)
      )

    if body do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(MlNotificationsWeb.Endpoint, method, path, Jason.encode!(body))
    else
      Phoenix.ConnTest.dispatch(conn, MlNotificationsWeb.Endpoint, method, path)
    end
  end
end
