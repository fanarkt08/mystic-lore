defmodule MlStudioWeb.ImageController do
  @moduledoc "Images: upload (base64 JSON), alt text, and the file itself for authorized members."
  use MlStudioWeb, :controller
  alias MlStudio.Images

  def create(conn, %{"id" => id} = params) do
    with {:ok, image} <- Images.upload(conn.assigns.user_id, id, params),
         do: conn |> put_status(201) |> json(%{image: View.image(image)})
  end

  def show(conn, %{"id" => id, "image_id" => image_id}) do
    with {:ok, image, path} <- Images.fetch(conn.assigns.user_id, id, image_id) do
      conn
      |> put_resp_content_type(image.content_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=300")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; style-src 'unsafe-inline'; sandbox"
      )
      |> send_file(200, path)
    end
  end

  def update(conn, %{"id" => id, "image_id" => image_id} = params) do
    with {:ok, image} <- Images.update(conn.assigns.user_id, id, image_id, params),
         do: json(conn, %{image: View.image(image)})
  end

  def delete(conn, %{"id" => id, "image_id" => image_id}) do
    with {:ok, _} <- Images.delete(conn.assigns.user_id, id, image_id),
         do: send_resp(conn, 204, "")
  end
end
