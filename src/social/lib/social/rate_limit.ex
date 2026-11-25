defmodule MlSocial.RateLimit do
  @moduledoc "Limite de débit des messages par membre, comptée en ETS sur chaque nœud."
  use GenServer

  @table __MODULE__
  @defaults [{20, 10_000}, {300, 3_600_000}]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Compte un message de `user_id` : `:ok` ou `{:error, {:rate_limited, secondes avant de réessayer}}`."
  def hit(user_id, now \\ System.system_time(:millisecond)) do
    Application.get_env(:social, :message_limits, @defaults)
    |> Enum.reduce_while([], fn {limit, window}, counted ->
      index = div(now, window)
      key = {user_id, window, index}
      expires_at = (index + 1) * window

      if :ets.update_counter(@table, key, {2, 1}, {key, 0, expires_at}) <= limit do
        {:cont, [key | counted]}
      else
        Enum.each([key | counted], &:ets.update_counter(@table, &1, {2, -1}))
        {:halt, {:error, {:rate_limited, max(div(expires_at - now + 999, 1000), 1)}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _counted -> :ok
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_purge()
    {:ok, nil}
  end

  @impl true
  def handle_info(:purge, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_purge()
    {:noreply, state}
  end

  defp schedule_purge, do: Process.send_after(self(), :purge, 60_000)
end
