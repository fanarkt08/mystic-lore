defmodule MlStudio.ServiceStub do
  @moduledoc """
  Stubs the other services by `{method, path}` and reports every call to the test process.
  """
  import Plug.Conn

  def stub_services(routes) do
    test = self()

    Req.Test.stub(MlShared.Client, fn conn ->
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      query = URI.decode_query(conn.query_string)

      send(
        test,
        {:service, %{method: conn.method, path: conn.request_path, query: query, body: body}}
      )

      case Map.get(routes, {conn.method, conn.request_path}, {404, %{"error" => "not_found"}}) do
        fun when is_function(fun, 2) -> respond(conn, fun.(conn, body))
        response -> respond(conn, response)
      end
    end)
  end

  @doc "Billing credit routes answering like the real ledger for one reservation at a time."
  def credit_routes(balance \\ 100) do
    %{
      {"POST", "/api/internal/credits/reserve"} => fn _conn, body ->
        %{
          "ref" => body["ref"],
          "status" => "held",
          "amount" => body["amount"],
          "balance" => balance - body["amount"],
          "reserved" => body["amount"]
        }
      end,
      {"POST", "/api/internal/credits/consume"} => fn _conn, body ->
        %{
          "ref" => body["ref"],
          "status" => "consumed",
          "amount" => 1,
          "balance" => balance,
          "reserved" => 0
        }
      end,
      {"POST", "/api/internal/credits/release"} => fn _conn, body ->
        %{
          "ref" => body["ref"],
          "status" => "released",
          "amount" => 1,
          "refunded" => 1,
          "balance" => balance,
          "reserved" => 0
        }
      end
    }
  end

  defp respond(conn, :unavailable), do: Req.Test.transport_error(conn, :econnrefused)
  defp respond(conn, {status, nil}), do: send_resp(conn, status, "")
  defp respond(conn, {status, body}), do: conn |> put_status(status) |> Req.Test.json(body)
  defp respond(conn, body), do: Req.Test.json(conn, body)
end
