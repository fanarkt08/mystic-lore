defmodule MysticWeb.Admin.AttachmentEvidenceController do
  @moduledoc """
  Sends the attachment of a reported message to the staff after social has audited the reason.
  """
  use MysticWeb, :controller
  alias MysticWeb.{Api, AttachmentController, Auth}

  def create(conn, %{"id" => id} = params) do
    reason = get_in(params, ["attachment", "reason"]) || ""

    with {:ok, user} <- Auth.resolve(get_session(conn, "session_token")),
         {:ok, bytes} when is_binary(bytes) <-
           Api.post(user, :social, "/api/moderation/reports/:id/attachment",
             path_params: [id: id],
             json: %{reason: String.trim(reason)},
             decode_body: false,
             receive_timeout: 15_000
           ),
         {:ok, type} <- AttachmentController.type(bytes) do
      AttachmentController.send_attachment(conn, type, bytes, true)
    else
      error ->
        conn
        |> put_flash(:error, message(error))
        |> redirect(to: ~p"/admin/reports/social/#{id}")
    end
  end

  defp message({:error, {:http, 422, _}}),
    do: gettext("Give a reason of at least 10 characters to open the attachment.")

  defp message({:error, {:http, status, _}} = error) when status in [403, 503],
    do: Api.error_message(decode(error))

  defp message(:anonymous), do: gettext("Please log in to continue.")
  defp message(_error), do: gettext("This attachment is no longer available.")

  # `decode_body: false`: the JSON error body of social arrives raw.
  defp decode({:error, {:http, status, body}}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:error, {:http, status, decoded}}
      _ -> {:error, {:http, status, %{}}}
    end
  end

  defp decode(error), do: error
end
