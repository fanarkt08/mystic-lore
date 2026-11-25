defmodule MysticWeb.AttachmentController do
  @moduledoc """
  Relays a conversation attachment from social, which checks on every download that the member belongs to it.
  """
  use MysticWeb, :controller
  alias MysticWeb.{Api, Auth}

  def show(conn, %{"id" => id}) do
    with {:ok, user} <- Auth.resolve(get_session(conn, "session_token")),
         {:ok, bytes} when is_binary(bytes) <-
           Api.get(user, :social, "/api/attachments/:id",
             path_params: [id: id],
             decode_body: false,
             receive_timeout: 15_000
           ),
         {:ok, type} <- type(bytes) do
      send_attachment(conn, type, bytes, type == "application/pdf")
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  @doc "Sends attachment bytes with the security headers (`download?`: always as a file to save)."
  def send_attachment(conn, type, bytes, download?) do
    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> then(
      &if(download?, do: put_resp_header(&1, "content-disposition", "attachment"), else: &1)
    )
    |> send_resp(200, bytes)
  end

  def type(<<0x89, "PNG", _::binary>>), do: {:ok, "image/png"}
  def type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def type(<<"%PDF-", _::binary>>), do: {:ok, "application/pdf"}
  def type(_bytes), do: :error
end
