defmodule MlAccountsWeb.StaffController do
  @moduledoc "Membres et indicateurs pour le staff ; rôles pour les admins (rôle vérifié par le routeur à chaque requête)."
  use MlAccountsWeb, :controller
  alias MlAccounts.Staff
  alias MlAccountsWeb.AdminJSON

  def stats(conn, _params), do: json(conn, %{stats: Staff.stats()})

  def index(conn, params) do
    viewer = conn.assigns.current_user
    page = Staff.list_members(viewer, params)
    json(conn, %{page | entries: Enum.map(page.entries, &AdminJSON.member(&1, viewer))})
  end

  def show(conn, %{"id" => id}) do
    viewer = conn.assigns.current_user

    with {:ok, user, sanctions} <- Staff.member_detail(viewer, id),
         do: json(conn, %{user: AdminJSON.member_detail(user, viewer, sanctions)})
  end

  @doc "Réinitialise l'avatar d'un membre (modérateur ou admin, motif obligatoire, audité)."
  def reset_avatar(conn, %{"id" => id} = params) do
    viewer = conn.assigns.current_user

    with {:ok, user} <- MlAccounts.Avatars.reset(viewer, id, params["reason"]),
         do: json(conn, %{user: AdminJSON.member(user, viewer)})
  end

  def set_role(conn, %{"id" => id} = params) do
    admin = conn.assigns.current_user

    with {:ok, user} <- Staff.set_role(admin, id, params),
         do: json(conn, %{user: AdminJSON.member(user, admin)})
  end
end
