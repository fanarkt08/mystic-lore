defmodule MlAccounts.Staff do
  @moduledoc """
  Outils du staff : rôles, membres et indicateurs. Le dernier admin ne peut jamais être rétrogradé.
  """
  import Ecto.Query
  alias MlAccounts.{Audit, Incident, Repo, Sanction, SanctionAppeal, User}
  alias MlShared.Events

  @per_page 25
  @roles ~w(user moderator admin)

  def staff?(%User{role: role}), do: role in ~w(moderator admin)
  def staff?(_), do: false
  def admin?(%User{role: role}), do: role == "admin"
  def admin?(_), do: false

  @doc "Page 1-based depuis un paramètre (invalide → 1)."
  def page(value) do
    case Integer.parse(to_string(value || "1")) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  @doc "« l•••@example.test »"
  def mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "•••@" <> domain
      _ -> "•••"
    end
  end

  @doc "`%{id => %{id, username, display_name}}` des membres demandés (une requête)."
  def people(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(
      from u in User,
        where: u.id in ^ids,
        select: {u.id, %{id: u.id, username: u.username, display_name: u.display_name}}
    )
    |> Map.new()
  end

  ## Membres

  @doc "Liste les membres actifs pour le staff ; la consultation des e-mails complets par un admin est auditée."
  def list_members(%User{} = viewer, params) do
    q = params["q"] |> to_string() |> String.trim() |> String.slice(0, 100)
    page = page(params["page"])

    query =
      from(u in User, where: is_nil(u.deleted_at))
      |> search(q, admin?(viewer))
      |> by_role(params["role"])

    total = Repo.aggregate(query, :count)

    members =
      Repo.all(
        from u in query,
          order_by: u.username,
          limit: @per_page,
          offset: ^((page - 1) * @per_page)
      )

    if admin?(viewer) do
      Audit.record!(viewer.id, "members.listed", "user", nil, nil, %{
        "q" => q,
        "page" => page,
        "count" => length(members)
      })
    end

    %{
      entries: members,
      page: page,
      total: total,
      total_pages: max(div(total + @per_page - 1, @per_page), 1)
    }
  end

  defp search(query, "", _admin?), do: query

  defp search(query, q, admin?) do
    prefix = String.replace(q, ["\\", "%", "_"], &"\\#{&1}") <> "%"

    if admin?,
      do:
        where(
          query,
          [u],
          ilike(u.username, ^prefix) or ilike(u.display_name, ^prefix) or ilike(u.email, ^prefix)
        ),
      else: where(query, [u], ilike(u.username, ^prefix) or ilike(u.display_name, ^prefix))
  end

  defp by_role(query, role) when role in @roles, do: where(query, [u], u.role == ^role)
  defp by_role(query, _), do: query

  @doc "Membre actif (non anonymisé) ou nil."
  def get_member(id) do
    case MlAccounts.get_user(id) do
      %User{deleted_at: nil} = user -> user
      _ -> nil
    end
  end

  @doc "Fiche d'un membre ; la consultation par un admin (e-mail complet) est auditée (`accounts.member.viewed`)."
  def member_detail(%User{} = viewer, id) do
    with %User{} = user <- get_member(id) do
      if admin?(viewer), do: Audit.record!(viewer.id, "member.viewed", "user", user.id, nil)
      {:ok, user, MlAccounts.Sanctions.for_user(user.id)}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Change le rôle d'un membre, jamais le sien ni celui du dernier admin."
  def set_role(%User{} = admin, target_id, params) do
    role = params["role"]
    reason = MlAccounts.Sanctions.trimmed(params["reason"])

    cond do
      role not in @roles ->
        {:error, {:invalid, %{role: ["is invalid"]}}}

      is_nil(reason) or String.length(reason) < 5 or String.length(reason) > 500 ->
        {:error, {:invalid, %{reason: ["should be 5 to 500 character(s)"]}}}

      true ->
        with %User{} = target <- get_member(target_id) || {:error, :not_found},
             :ok <- if(target.id == admin.id, do: {:error, :self}, else: :ok) do
          change_role(admin, target, role, reason)
        end
    end
  end

  # Admins qui resteront actifs : ni le membre visé, ni un compte supprimé ou dont la suppression est programmée.
  defp active_admins_besides(admin_ids, target_id) do
    Repo.aggregate(
      from(u in User,
        where:
          u.id in ^admin_ids and u.id != ^target_id and is_nil(u.deletion_scheduled_at) and
            is_nil(u.deleted_at)
      ),
      :count
    )
  end

  defp change_role(admin, target, role, reason) do
    Repo.transact(fn ->
      # verrou : toutes les lignes admin, puis le membre visé
      admins =
        Repo.all(from u in User, where: u.role == "admin", lock: "FOR UPDATE", select: u.id)

      target = Repo.one!(from u in User, where: u.id == ^target.id, lock: "FOR UPDATE")

      cond do
        target.role == role ->
          {:ok, {target, false}}

        target.role == "admin" and active_admins_besides(admins, target.id) == 0 ->
          {:error, :last_admin}

        admin.id not in admins ->
          {:error, :forbidden}

        true ->
          updated = target |> Ecto.Changeset.change(role: role) |> Repo.update!()

          Audit.record!(admin.id, "role.changed", "user", target.id, reason, %{
            "from" => target.role,
            "to" => role
          })

          {:ok, {updated, true}}
      end
    end)
    |> case do
      {:ok, {user, changed?}} ->
        if changed? do
          Events.broadcast(Events.user(user.id), {:role_changed, user.id})
          Events.broadcast("members", {:role_changed, user.id})
        end

        {:ok, user}

      error ->
        error
    end
  end

  ## Indicateurs (comptes réels, aucune estimation)

  def stats(now \\ DateTime.utc_now()) do
    week_ago = DateTime.add(now, -7, :day)
    members = from(u in User, where: is_nil(u.deleted_at))

    %{
      members: Repo.aggregate(members, :count),
      new_7d: Repo.aggregate(where(members, [u], u.inserted_at > ^week_ago), :count),
      confirmed: Repo.aggregate(where(members, [u], not is_nil(u.confirmed_at)), :count),
      restricted: Repo.aggregate(where(members, [u], u.restricted_until > ^now), :count),
      open_appeals: Repo.aggregate(from(a in SanctionAppeal, where: a.status == "open"), :count),
      sanctions_7d: Repo.aggregate(from(s in Sanction, where: s.inserted_at > ^week_ago), :count),
      open_incidents: Repo.aggregate(from(i in Incident, where: i.status != "resolved"), :count)
    }
  end
end
