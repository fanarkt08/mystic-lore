defmodule MysticWeb.Studio.MediaController do
  @moduledoc """
  Proxies of the video-lesson media. Learners only get the media of the version published in learning.
  """
  use MysticWeb, :controller
  alias MysticWeb.{Api, Auth}

  def show(conn, %{"id" => id, "media_id" => media_id}),
    do: relay(conn, "/api/projects/:id/media/:media_id", id: id, media_id: media_id)

  def published(conn, %{"media_id" => media_id}),
    do: relay(conn, "/api/media/:media_id", media_id: media_id)

  defp relay(conn, path, params) do
    with {:ok, user} <- Auth.resolve(get_session(conn, "session_token")),
         {:ok, bytes} when is_binary(bytes) <-
           Api.get(user, :studio, path,
             path_params: params,
             decode_body: false,
             receive_timeout: 30_000
           ),
         {:ok, type} <- type(bytes) do
      conn
      |> put_resp_content_type(type, if(type == "text/vtt", do: "utf-8"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=300")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  defp type(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: {:ok, "video/webm"}
  defp type(<<_::binary-size(4), "ftyp", _::binary>>), do: {:ok, "video/mp4"}
  defp type(<<0xEF, 0xBB, 0xBF, "WEBVTT", _::binary>>), do: {:ok, "text/vtt"}
  defp type(<<"WEBVTT", _::binary>>), do: {:ok, "text/vtt"}
  defp type(_bytes), do: :error
end
