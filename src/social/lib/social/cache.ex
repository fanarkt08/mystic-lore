defmodule MlSocial.Cache do
  @moduledoc "Cache ETS court des rôles et restrictions lus chez accounts, invalidé par le topic `\"members\"`."
  use GenServer

  @table __MODULE__
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Valeur fraîche de `key`, sinon résultat de `fun.()` (gardé `ttl_ms` s'il vaut `{:ok, valeur}`)."
  def fetch(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{_key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      _ ->
        with {:ok, value} <- fun.() do
          :ets.insert(@table, {key, value, now + ttl_ms})
          {:ok, value}
        end
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok = MlShared.Events.subscribe("members")
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info({tag, id}, state) when tag in [:sanction_changed, :role_changed] do
    :ets.delete(@table, {:member, id})
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
