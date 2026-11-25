defmodule MysticWeb.Studio.ImageController do
  @moduledoc "Proxy of the private images of a studio project, authorized by the studio."
  use MysticWeb, :controller
  alias MysticWeb.{Api, Auth}

  def show(conn, %{"id" => id, "image_id" => image_id}) do
    with {:ok, user} <- Auth.resolve(get_session(conn, "session_token")),
         {:ok, bytes} when is_binary(bytes) <-
           Api.get(user, :studio, "/api/projects/:id/images/:image_id",
             path_params: [id: id, image_id: image_id],
             decode_body: false
           ),
         {:ok, type} <- type(bytes) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=300")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; style-src 'unsafe-inline'; sandbox"
      )
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  defp type(<<0x89, "PNG", _::binary>>), do: {:ok, "image/png"}
  defp type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp type(<<"<svg", _::binary>>), do: {:ok, "image/svg+xml"}
  defp type(_bytes), do: :error
end
