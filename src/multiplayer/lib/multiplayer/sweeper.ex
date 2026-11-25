defmodule MlMultiplayer.Sweeper do
  @moduledoc "Tâche périodique qui applique la présence et livre les récompenses dues."
  use GenServer
  require Logger
  alias MlMultiplayer.{Presence, Rewards}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Livraison immédiate des récompenses dues (sans effet si le balayage est désactivé)."
  def deliver_now, do: GenServer.cast(__MODULE__, :deliver)

  @impl true
  def init(_) do
    case MlMultiplayer.rule(:sweep_interval) do
      false ->
        :ignore

      interval ->
        send(self(), :tick)
        {:ok, interval}
    end
  end

  @impl true
  def handle_info(:tick, interval) do
    safely(fn -> Presence.sweep() end)
    safely(fn -> Rewards.deliver_due() end)
    Process.send_after(self(), :tick, interval)
    {:noreply, interval}
  end

  @impl true
  def handle_cast(:deliver, interval) do
    safely(fn -> Rewards.deliver_due() end)
    {:noreply, interval}
  end

  # Une base momentanément indisponible ne doit pas arrêter le balayage ; aucun détail de données journalisé.
  defp safely(fun) do
    fun.()
  rescue
    error -> Logger.error("multiplayer sweep failed: #{inspect(error.__struct__)}")
  catch
    :exit, _reason -> Logger.error("multiplayer sweep failed: exit")
  end
end
