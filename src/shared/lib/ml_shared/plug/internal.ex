defmodule MlShared.Plug.Internal do
  @moduledoc """
  Exige un jeton interne valide (`authorization: Bearer <jeton>`) et assigne `:caller` et `:user_id`.
  Avec `user: :required`, répond 401 si le jeton ne porte pas d'utilisateur.
  """
  import Plug.Conn
  alias MlShared.InternalToken

  def init(opts), do: Keyword.get(opts, :user, :optional)

  def call(conn, user_mode) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{"svc" => svc} = data} <- InternalToken.verify(token),
         :ok <- check_user(user_mode, data["sub"]) do
      conn |> assign(:caller, svc) |> assign(:user_id, data["sub"])
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end

  defp check_user(:required, sub) when is_binary(sub), do: :ok
  defp check_user(:required, _), do: :error
  defp check_user(_, _), do: :ok
end
