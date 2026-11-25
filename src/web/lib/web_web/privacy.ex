defmodule MysticWeb.Privacy do
  @moduledoc "Data exports and account deletion, all through accounts."
  use Gettext, backend: MysticWeb.Gettext
  alias MysticWeb.{Api, Auth}
  alias Phoenix.{Component, LiveView}

  @doc "Cancels the scheduled deletion, then reloads the member from accounts (the banner goes away)."
  def cancel_deletion(socket) do
    case Api.delete(socket, :accounts, "/api/me/deletion") do
      {:ok, _} ->
        socket
        |> refresh_user()
        |> LiveView.put_flash(:info, gettext("Deletion cancelled: your account stays open."))

      # already cancelled (another tab)
      {:error, {:http, 404, _}} ->
        refresh_user(socket)

      error ->
        LiveView.put_flash(socket, :error, Api.error_message(error))
    end
  end

  defp refresh_user(socket) do
    case Auth.resolve(Auth.session_token(socket)) do
      {:ok, user} -> Component.assign(socket, :current_user, user)
      _ -> socket
    end
  end
end
