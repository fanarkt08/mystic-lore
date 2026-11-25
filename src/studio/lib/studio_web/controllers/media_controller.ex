defmodule MlStudioWeb.MediaController do
  @moduledoc "Media of the video lessons: video upload, caption tracks and the files themselves."
  use MlStudioWeb, :controller
  alias MlStudio.Media

  def upload_video(conn, %{"id" => id, "lesson_id" => lesson_id}) do
    case read_body(conn,
           length: Media.max_video_bytes(),
           read_length: 1_048_576,
           read_timeout: 60_000
         ) do
      {:ok, data, conn} ->
        with {:ok, %{medium: medium, lesson: lesson}} <-
               Media.upload_video(conn.assigns.user_id, id, lesson_id, data),
             do:
               conn
               |> put_status(201)
               |> json(%{media: View.medium(medium), lesson: View.lesson(lesson)})

      {:more, _partial, conn} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid", errors: %{data: ["must be at most 50 MB"]}})

      {:error, _reason} ->
        conn |> put_status(422) |> json(%{error: "invalid", errors: %{data: ["can't be read"]}})
    end
  end

  def create_captions(conn, %{"id" => id, "lesson_id" => lesson_id} = params) do
    with {:ok, %{medium: medium, lesson: lesson}} <-
           Media.add_captions(conn.assigns.user_id, id, lesson_id, params),
         do:
           conn
           |> put_status(201)
           |> json(%{media: View.medium(medium), lesson: View.lesson(lesson)})
  end

  def delete_captions(conn, %{"id" => id, "lesson_id" => lesson_id, "lang" => lang}) do
    with {:ok, :deleted} <- Media.delete_captions(conn.assigns.user_id, id, lesson_id, lang),
         do: send_resp(conn, 204, "")
  end

  def show(conn, %{"id" => id, "media_id" => media_id}) do
    with {:ok, medium, path} <- Media.fetch(conn.assigns.user_id, id, media_id),
         do: send_medium(conn, medium, path, "private, max-age=300")
  end

  def published(conn, %{"media_id" => media_id}) do
    with {:ok, medium, path} <- Media.fetch_published(media_id),
         do: send_medium(conn, medium, path, "private, max-age=3600")
  end

  defp send_medium(conn, medium, path, cache) do
    conn
    |> put_resp_content_type(medium.content_type, if(medium.kind == "captions", do: "utf-8"))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", cache)
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> send_file(200, path)
  end
end
