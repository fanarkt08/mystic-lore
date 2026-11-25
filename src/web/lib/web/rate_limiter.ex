defmodule Mystic.RateLimiter do
  @moduledoc "Fixed-window, in-memory rate limiter (ETS); counters are per node."
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Counts one hit for `key` in `bucket` and returns `:ok` or `{:error, retry_after_seconds}`."
  def hit(bucket, key, limit, window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    expires_at = (window + 1) * window_ms
    row = {bucket, key, window}
    count = :ets.update_counter(@table, row, {2, 1}, {row, 0, expires_at})

    if count <= limit, do: :ok, else: {:error, max(div(expires_at - now + 999, 1000), 1)}
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_purge()
    {:ok, nil}
  end

  @impl true
  def handle_info(:purge, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_purge()
    {:noreply, state}
  end

  defp schedule_purge, do: Process.send_after(self(), :purge, 60_000)
end
