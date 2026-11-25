defmodule MlCommunity.Social do
  @moduledoc """
  Blocages lus chez social (dans les deux sens), en cache 15 s et invalidés dès que social publie un changement.
  Si social est injoignable, `{:error, :unavailable}`, jamais une liste vide par défaut.
  """
  require Logger
  alias MlCommunity.Cache

  @ttl_ms 15_000

  def blocked_ids(user_id) do
    Cache.fetch({:blocks, user_id}, @ttl_ms, fn ->
      :ok = Cache.watch(user_id)

      case MlShared.Client.get(:social, "/api/internal/blocks/:id", path_params: [id: user_id]) do
        {:ok, %{"user_ids" => ids}} when is_list(ids) ->
          {:ok, for(id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid)}

        other ->
          Logger.warning("social unavailable for blocks: #{inspect(summary(other))}")
          {:error, :unavailable}
      end
    end)
  end

  defp summary({:error, {:http, status, _body}}), do: {:http, status}
  defp summary({:error, reason}), do: reason
  defp summary({:ok, _body}), do: :unexpected_body
end
