defmodule MlSocialWeb.AttachmentController do
  @moduledoc "Sert une pièce jointe à un membre actuel de sa conversation, et 404 à tout autre."
  use MlSocialWeb, :controller
  alias MlSocial.Attachments

  action_fallback MlSocialWeb.FallbackController

  def show(conn, %{"id" => id}) do
    with {:ok, attachment, data} <- Attachments.read(conn.assigns.user_id, id),
         do: send_file_bytes(conn, attachment, data)
  end

  @doc false
  def send_file_bytes(conn, attachment, data) do
    conn
    |> put_resp_content_type(attachment.content_type, nil)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, no-store")
    |> send_resp(200, data)
  end
end
