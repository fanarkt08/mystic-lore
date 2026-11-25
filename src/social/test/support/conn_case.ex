defmodule MlSocialWeb.ConnCase do
  @moduledoc """
  Tests HTTP : sandbox SQL, requêtes signées comme le ferait `web` (`as_user/2`) et faux accounts
  (`fake_accounts/1`) installé par défaut pour `MlShared.Client` (chaque test peut le remplacer).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MlSocialWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import MlSocial.Fixtures
      import MlSocialWeb.ConnCase
    end
  end

  setup tags do
    MlSocial.DataCase.setup_sandbox(tags)
    Req.Test.stub(MlShared.Client, &fake_accounts/1)
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
      |> Phoenix.ConnTest.dispatch(MlSocialWeb.Endpoint, method, path, Jason.encode!(body))
    else
      Phoenix.ConnTest.dispatch(conn, MlSocialWeb.Endpoint, method, path)
    end
  end

  @doc "Installe de faux accounts et un faux centre de notifications pour `MlShared.Client`."
  def fake_accounts(%Plug.Conn{request_path: "/api/users"} = conn) do
    ids = String.split(conn.query_params["ids"] || "", ",", trim: true)
    Req.Test.json(conn, %{"users" => Enum.map(ids, &fake_user/1)})
  end

  def fake_accounts(%Plug.Conn{request_path: "/api/internal/users/" <> id} = conn),
    do: Req.Test.json(conn, %{"user" => internal_user(id)})

  def fake_accounts(%Plug.Conn{method: "POST", request_path: "/api/internal/audit"} = conn),
    do: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

  # Faux centre de notifications : chaque appel est rapporté au processus appelant (le test, les notifications
  # étant envoyées dans le processus de la requête en test) par `{:center, chemin, corps}`.
  def fake_accounts(
        %Plug.Conn{method: "POST", request_path: "/api/internal/notifications" <> _} = conn
      ) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(self(), {:center, conn.request_path, Jason.decode!(raw)})
    conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"status" => "created"})
  end

  def internal_user(id, role \\ "user", restricted_until \\ nil),
    do:
      Map.merge(fake_user(id), %{
        "role" => role,
        "confirmed" => true,
        "restricted_until" => restricted_until
      })

  def fake_user(id) do
    short = String.slice(id, 0, 8)

    %{
      "id" => id,
      "username" => "user_#{short}",
      "display_name" => "User #{short}",
      "avatar" => nil
    }
  end
end
