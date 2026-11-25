defmodule MlLearning.Entitlements do
  @moduledoc """
  Droits premium lus chez billing et gardés 30 s en cache.
  Si billing est injoignable, l'accès premium est refusé, jamais ouvert par défaut.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 30_000
  @premium_plans ~w(premium vip)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`:ok` | `{:error, :premium_required}` | `{:error, :entitlements_unavailable}`."
  def check(%{premium: false}, _user_id), do: :ok

  def check(%{premium: true}, user_id) do
    case premium?(user_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :premium_required}
      {:error, :unavailable} -> {:error, :entitlements_unavailable}
    end
  end

  @doc "`{:ok, boolean}` (cache 30 s) ou `{:error, :unavailable}`."
  def premium?(user_id) when is_binary(user_id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, user_id) do
      [{_, premium, expires_at}] when expires_at > now -> {:ok, premium}
      _ -> with {:ok, %{premium: premium}} <- fresh(user_id), do: {:ok, premium}
    end
  end

  @doc "Relit les droits chez billing sans le cache, avec la fin de la période payée."
  def fresh(user_id) when is_binary(user_id) do
    case MlShared.Client.get(:billing, "/api/entitlements/" <> URI.encode_www_form(user_id)) do
      {:ok, %{"plan" => plan, "status" => status} = entitlements} ->
        # `plan` est déjà la formule effective : seul un abonnement terminé est incohérent.
        premium = plan in @premium_plans and status in ["active", "past_due"]
        :ets.insert(@table, {user_id, premium, System.monotonic_time(:millisecond) + @ttl_ms})
        {:ok, %{premium: premium, period_end: datetime(entitlements["current_period_end"])}}

      _ ->
        {:error, :unavailable}
    end
  end

  defp datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _ -> nil
    end
  end

  defp datetime(_iso), do: nil

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok = MlShared.Events.subscribe("entitlements")
    {:ok, nil}
  end

  @impl true
  def handle_info({:entitlements_changed, user_id, _plan}, state) do
    :ets.delete(@table, user_id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
