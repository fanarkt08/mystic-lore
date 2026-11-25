defmodule MlCommunity.Accounts do
  @moduledoc """
  Appels à accounts : profils des auteurs, rôle et restriction d'un membre, et journal d'audit.
  Seul le rôle lu ici ouvre les droits du staff, jamais ce qu'envoie le client.
  """
  require Logger
  alias MlCommunity.Cache

  @batch 100
  @role_ttl_ms 30_000
  @staff_roles ~w(moderator admin)

  @doc "`%{id => user public}` pour chaque id demandé."
  def users(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    found =
      ids
      |> Enum.chunk_every(@batch)
      |> Enum.flat_map(&fetch_users/1)
      |> Map.new(&{&1["id"], &1})

    Map.new(ids, &{&1, Map.get(found, &1, public(%{"id" => &1}))})
  end

  defp fetch_users(ids) do
    case MlShared.Client.get(:accounts, "/api/users",
           params: [ids: Enum.join(ids, ",")],
           retry: false
         ) do
      {:ok, %{"users" => users}} when is_list(users) ->
        for %{"id" => _} = user <- users, do: public(user)

      other ->
        Logger.warning("accounts unavailable for author profiles: #{inspect(summary(other))}")
        []
    end
  end

  defp public(user), do: Map.new(~w(id username display_name avatar), &{&1, user[&1]})

  @doc "`{:ok, %{role, restricted_until}}` (membre inconnu : rôle nil) ou `{:error, :unavailable}`."
  def member(user_id) do
    Cache.fetch({:member, user_id}, @role_ttl_ms, fn ->
      case MlShared.Client.get(:accounts, "/api/internal/users/:id", path_params: [id: user_id]) do
        {:ok, %{"user" => %{"role" => role} = user}} ->
          {:ok, %{role: role, restricted_until: datetime(user["restricted_until"])}}

        {:error, {:http, 404, _}} ->
          {:ok, %{role: nil, restricted_until: nil}}

        other ->
          Logger.warning("accounts unavailable for role check: #{inspect(summary(other))}")
          {:error, :unavailable}
      end
    end)
  end

  @doc "`{:ok, true}` (moderator, admin), `{:ok, false}` (autre rôle, membre inconnu) ou `{:error, :unavailable}`."
  def staff?(user_id) do
    with {:ok, %{role: role}} <- member(user_id), do: {:ok, role in @staff_roles}
  end

  @doc "Écrit une entrée d'audit (`community.…`) ; `{:error, :audit_unavailable}` si accounts ne l'a pas enregistrée."
  def audit(actor_id, action, target_type, target_id, reason, metadata \\ %{}) do
    case MlShared.Client.post(:accounts, "/api/internal/audit",
           json: %{
             actor_id: actor_id,
             action: action,
             target_type: target_type,
             target_id: target_id,
             reason: reason,
             metadata: metadata
           }
         ) do
      {:ok, %{"id" => _}} ->
        :ok

      other ->
        Logger.error("audit entry #{action} not recorded: #{inspect(summary(other))}")
        {:error, :audit_unavailable}
    end
  end

  defp datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  # Jamais de corps de réponse dans les journaux.
  defp summary({:error, {:http, status, _body}}), do: {:http, status}
  defp summary({:error, reason}), do: reason
  defp summary({:ok, _body}), do: :unexpected_body
end
