defmodule MlMultiplayer.Accounts do
  @moduledoc """
  Identités publiques et rôles des membres lus chez accounts. Si accounts ne répond pas, le chat est refusé.
  """
  require Logger
  alias MlMultiplayer.Cache

  @batch 100
  @member_ttl_ms 10_000

  @doc "`%{id => user public}` pour chaque id demandé (les `nil` sont ignorés)."
  def users(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    found =
      ids
      |> Enum.chunk_every(@batch)
      |> Enum.flat_map(&fetch/1)
      |> Map.new(&{&1["id"], &1})

    Map.new(ids, &{&1, Map.get(found, &1, public(%{"id" => &1}))})
  end

  defp fetch(ids) do
    case MlShared.Client.get(:accounts, "/api/users",
           params: [ids: Enum.join(ids, ",")],
           retry: false
         ) do
      {:ok, %{"users" => users}} when is_list(users) ->
        for %{"id" => _} = user <- users, do: public(user)

      other ->
        Logger.warning("accounts unavailable for member profiles: #{inspect(summary(other))}")
        []
    end
  end

  defp public(user), do: Map.new(~w(id username display_name avatar), &{&1, user[&1]})

  @doc "`{:ok, %{role, restricted_until}}` (membre inconnu : rôle nil) ou `{:error, :unavailable}`."
  def member(user_id) do
    Cache.fetch({:member, user_id}, @member_ttl_ms, fn ->
      case MlShared.Client.get(:accounts, "/api/internal/users/:id", path_params: [id: user_id]) do
        {:ok, %{"user" => %{"role" => role} = user}} ->
          {:ok, %{role: role, restricted_until: datetime(user["restricted_until"])}}

        {:error, {:http, 404, _}} ->
          {:ok, %{role: nil, restricted_until: nil}}

        other ->
          Logger.warning("accounts unavailable for member status: #{inspect(summary(other))}")
          {:error, :unavailable}
      end
    end)
  end

  @doc "`:ok` pour un modérateur ou un admin, sinon `{:error, :forbidden}` ou `{:error, :roles_unavailable}`."
  def require_staff(user_id) do
    case member(user_id) do
      {:ok, %{role: role}} when role in ~w(moderator admin) -> :ok
      {:ok, _} -> {:error, :forbidden}
      {:error, :unavailable} -> {:error, :roles_unavailable}
    end
  end

  @doc "`:ok`, `{:error, {:restricted, fin}}`, ou `{:error, :accounts_unavailable}` (refus par prudence)."
  def check_not_restricted(user_id, now \\ DateTime.utc_now()) do
    case member(user_id) do
      {:ok, %{restricted_until: %DateTime{} = until}} ->
        if DateTime.after?(until, now), do: {:error, {:restricted, until}}, else: :ok

      {:ok, _} ->
        :ok

      {:error, :unavailable} ->
        {:error, :accounts_unavailable}
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
