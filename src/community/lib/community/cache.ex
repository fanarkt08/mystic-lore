defmodule MlCommunity.Cache do
  @moduledoc "Cache ETS court des blocages et des rôles, invalidé dès que social ou accounts publient un changement."
  use GenServer
  alias MlShared.Events

  @table __MODULE__
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Valeur fraîche de `key`, sinon résultat de `fun.()` (mis en cache `ttl_ms` s'il vaut `{:ok, valeur}`)."
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

  @doc "Abonne le cache aux événements de `user_id` (invalidation de ses blocages)."
  def watch(user_id), do: GenServer.call(__MODULE__, {:watch, user_id})

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # rôles et restrictions : accounts publie chaque changement sur "members"
    :ok = Events.subscribe("members")
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, MapSet.new()}
  end

  @impl true
  def handle_call({:watch, id}, _from, watched) do
    if MapSet.member?(watched, id) do
      {:reply, :ok, watched}
    else
      :ok = Events.subscribe(Events.user(id))
      {:reply, :ok, MapSet.put(watched, id)}
    end
  end

  @impl true
  def handle_info({:friendship_changed, id}, watched) do
    :ets.delete(@table, {:blocks, id})
    {:noreply, watched}
  end

  def handle_info({tag, id}, watched) when tag in [:sanction_changed, :role_changed] do
    :ets.delete(@table, {:member, id})
    {:noreply, watched}
  end

  def handle_info(:sweep, watched) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    cached = MapSet.new(:ets.select(@table, [{{{:blocks, :"$1"}, :_, :_}, [], [:"$1"]}]))
    for id <- MapSet.difference(watched, cached), do: Events.unsubscribe(Events.user(id))
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, MapSet.intersection(watched, cached)}
  end

  # Autres événements des membres suivis (non-lus, droits, notifications du forum…) : sans objet ici.
  def handle_info(_message, watched), do: {:noreply, watched}
end
