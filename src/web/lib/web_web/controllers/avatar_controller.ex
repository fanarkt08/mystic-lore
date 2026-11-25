defmodule MysticWeb.AvatarController do
  @moduledoc "Relays uploaded avatars from accounts, with their random name as cache version."
  use MysticWeb, :controller
  alias MysticWeb.Api

  @max_bytes 2_097_152

  def show(conn, %{"key" => key}) do
    with true <- Regex.match?(~r/\A[0-9a-f]{32}\.(png|jpg|webp)\z/, key),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_bytes <-
           Api.get(nil, :accounts, "/api/avatars/:key",
             path_params: [key: key],
             decode_body: false
           ),
         {:ok, type} <- type(bytes) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "public, max-age=86400, immutable")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  defp type(<<0x89, "PNG", _::binary>>), do: {:ok, "image/png"}
  defp type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp type(_bytes), do: :error
end
