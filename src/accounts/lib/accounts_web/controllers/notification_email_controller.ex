defmodule MlAccountsWeb.NotificationEmailController do
  @moduledoc """
  Envoie un e-mail demandé par le centre de notifications, et répond 200 seulement une fois l'e-mail remis.
  """
  use MlAccountsWeb, :controller
  require Logger
  import Ecto.Query
  alias MlAccounts.{Mailer, NotificationEmail, Repo, User}

  plug :notifications_only

  def create(conn, %{"id" => id} = params) do
    with %User{} = user <- MlAccounts.get_user(id) || :not_found,
         :ok <- deliverable(user),
         {:ok, email} <- NotificationEmail.build(user, params, names(params)) do
      case Mailer.deliver(email) do
        {:ok, _} ->
          json(conn, %{status: "sent"})

        {:error, reason} ->
          Logger.error("notification email not delivered to user #{user.id}: #{inspect(reason)}")
          conn |> put_status(503) |> json(%{error: "mailer_unavailable"})
      end
    else
      :not_found -> conn |> put_status(404) |> json(%{error: "not_found"})
      :not_deliverable -> conn |> put_status(409) |> json(%{error: "not_deliverable"})
      {:error, :invalid} -> conn |> put_status(422) |> json(%{error: "invalid"})
    end
  end

  defp deliverable(%User{confirmed_at: nil}), do: :not_deliverable

  defp deliverable(user),
    do: if(MlAccounts.Privacy.deleting?(user), do: :not_deliverable, else: :ok)

  # noms affichés des acteurs cités (un compte supprimé s'affiche « Deleted member », son nom anonymisé)
  defp names(params) do
    ids = NotificationEmail.actor_ids(params)

    Repo.all(from u in User, where: u.id in ^ids, select: {u.id, u.display_name})
    |> Map.new()
  end

  defp notifications_only(%{assigns: %{caller: "notifications"}} = conn, _opts), do: conn

  defp notifications_only(conn, _opts),
    do: conn |> put_status(403) |> json(%{error: "forbidden"}) |> halt()
end
