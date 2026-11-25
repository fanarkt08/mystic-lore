defmodule MysticWeb.ApiStub do
  @moduledoc """
  Stubs the internal services by `{method, path}` and reports every call to the test process.
  """
  import Plug.Conn

  def stub_api(routes) do
    test = self()

    Req.Test.stub(MlShared.Client, fn conn ->
      {:ok, raw, conn} = read_body(conn)
      # JSON bodies are decoded; a raw upload (video bytes) is passed as is
      body =
        case raw do
          "" ->
            nil

          raw ->
            case Jason.decode(raw) do
              {:ok, decoded} -> decoded
              {:error, _} -> raw
            end
        end

      query = URI.decode_query(conn.query_string)

      send(
        test,
        {:api, %{method: conn.method, path: conn.request_path, query: query, body: body}}
      )

      case Map.get(routes, {conn.method, conn.request_path}, {404, %{"error" => "not_found"}}) do
        fun when is_function(fun, 2) -> respond(conn, fun.(conn, body))
        response -> respond(conn, response)
      end
    end)
  end

  # a route function may answer itself (raw body, custom content type)
  defp respond(_conn, %Plug.Conn{state: :sent} = sent), do: sent
  defp respond(conn, :unavailable), do: Req.Test.transport_error(conn, :econnrefused)
  defp respond(conn, {status, nil}), do: send_resp(conn, status, "")
  defp respond(conn, {status, body}), do: conn |> put_status(status) |> Req.Test.json(body)
  defp respond(conn, body), do: Req.Test.json(conn, body)
end
