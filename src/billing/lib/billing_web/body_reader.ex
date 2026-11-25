defmodule MlBillingWeb.BodyReader do
  @moduledoc "Body reader of `Plug.Parsers` that keeps the raw body (`:raw_body`) of the Stripe webhook only."

  def read_body(%Plug.Conn{request_path: "/webhooks/stripe"} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
      other -> other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
