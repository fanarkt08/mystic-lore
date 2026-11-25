defmodule MlAccountsWeb.LastAdminTest do
  # Comptes admin globaux (comptage de tous les admins) : pas en parallèle avec les autres tests qui créent des admins.
  use MlAccountsWeb.ConnCase, async: false
  alias MlAccounts.User

  @moduletag :capture_log

  defp admin_fixture do
    user_fixture() |> Ecto.Changeset.change(role: "admin") |> Repo.update!()
  end

  defp schedule(user),
    do:
      build_conn()
      |> internal(user.id)
      |> post("/api/me/deletion", %{password: password(), confirm_username: user.username})

  setup do
    # point de départ connu : aucun autre admin dans la base de test
    Repo.update_all(User, set: [role: "user"])
    :ok
  end

  test "the last active admin cannot schedule their own deletion; with a second admin, it is allowed" do
    a = admin_fixture()
    assert %{"error" => "last_admin"} = schedule(a) |> json_response(409)
    assert is_nil(Repo.get!(User, a.id).deletion_scheduled_at)

    b = admin_fixture()
    assert schedule(a) |> json_response(200)
    refute is_nil(Repo.get!(User, a.id).deletion_scheduled_at)

    # b est désormais le seul admin actif (a part) : b ne peut plus programmer sa propre suppression
    assert %{"error" => "last_admin"} = schedule(b) |> json_response(409)
  end

  test "an admin whose deletion is pending does not count when demoting another admin" do
    a = admin_fixture()
    b = admin_fixture()
    c = admin_fixture()
    assert schedule(a) |> json_response(200)

    # c rétrograde b : il resterait c (actif) → autorisé
    assert build_conn()
           |> internal(c.id)
           |> put("/api/admin/users/#{b.id}/role", %{role: "user", reason: "rotation"})
           |> json_response(200)

    # c ne peut pas se rétrograder lui-même, et personne ne peut rétrograder le dernier admin actif
    d = admin_fixture()
    assert schedule(d) |> json_response(200)

    assert %{"error" => "last_admin"} =
             build_conn()
             |> internal(d.id)
             |> put("/api/admin/users/#{c.id}/role", %{role: "user", reason: "rotation"})
             |> json_response(409)
  end
end
